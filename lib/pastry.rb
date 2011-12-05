require 'fileutils'
require 'logger'
require 'socket'
require 'thin'
require 'thin/server'

class Pastry
  # have defaults
  attr_accessor :pool, :host, :port, :queue, :max_connections, :timeout, :daemonize, :pidfile

  # no defaults
  attr_accessor :name, :socket, :logfile, :start_command

  def initialize pool, app, options = {}
    @pool             = pool
    @app              = app
    @host             = options.fetch :host,            '127.0.0.1'
    @port             = options.fetch :port,            3000
    @queue            = options.fetch :queue,           1024
    @max_connections  = options.fetch :max_connections, 1024
    @timeout          = options.fetch :timeout,           30
    @daemonize        = options.fetch :daemonize,       false
    @pidfile          = options.fetch :pidfile,         '/tmp/pastry.pid'
    @name             = options.fetch :name,            nil
    @socket           = options.fetch :socket,          nil
    @logfile          = options.fetch :logfile,         nil
    @start_command    = options.fetch :start_command,   nil

    @before_fork      = nil
    @after_fork       = nil
  end

  def before_fork &block
    raise ArgumentError, 'missing callback' unless block
    @before_fork = block
  end

  def after_fork &block
    raise ArgumentError, 'missing callback' unless block
    @after_fork = block
  end

  def parse_config file
    instance_eval File.read(file)
  end

  def start
    do_sanity_checks
    ensure_not_running!

    Process.daemon if daemonize

    if daemonize || logfile
      STDOUT.reopen(logfile || '/tmp/pastry.log', 'a')
      STDERR.reopen(logfile || '/tmp/pastry.log', 'a')
      STDOUT.sync = true
      STDERR.sync = true
      STDOUT.binmode
      STDERR.binmode
    end

    start!
  end

  private

  attr_accessor :pids

  def do_sanity_checks
    %w(port queue max_connections timeout).each {|var| send("#{var}=", send(var).to_i)}
  end

  def ensure_not_running!
    if File.exists?(pidfile) && pid = File.read(pidfile).to_i
      running = Process.kill(0, pid) rescue nil
      raise "already running with pid #{pid}" if running
      FileUtils.rm_f([pidfile, socket.to_s])
    end
  end

  def create_pidfile
    File.open(pidfile, 'w') {|fh| fh.write(Process.pid)}
  end

  def master_name
    '%s master' % (name || 'pastry')
  end

  def motd
    "starting #{master_name} with #{pool} minions listening on #{socket ? 'socket %s ' % socket : 'port %d' % port}"
  end

  def logger
    @logger ||= Logger.new(logfile || (daemonize ? '/tmp/pastry.log' : $stdout), 0)
  end

  def start!
    create_pidfile
    server   = ENV['PASTRY_FD'] && Socket.for_fd(ENV['PASTRY_FD'].to_i)
    server ||= socket ? UNIXServer.new(socket) : TCPServer.new(host, port)

    server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true) unless socket
    server.fcntl(Fcntl::F_SETFD, server.fcntl(Fcntl::F_GETFD) | Fcntl::FD_CLOEXEC)
    server.fcntl(Fcntl::F_SETFL, server.fcntl(Fcntl::F_GETFL) | Fcntl::O_NONBLOCK)
    server.autoclose = false

    server.listen(queue)
    server.extend(PastryServer)

    server.app = @app
    logger.info motd

    # make this world readable.
    FileUtils.chmod(0777, socket) if socket

    # pre-fork cleanups, let user cleanup any leaking fds.
    @before_fork && @before_fork.call

    $0         = "#{name} master (started: #{Time.now})" if name
    @running   = true
    @pids      = pool.times.map {|idx| run(server, idx) }

    Signal.trap('CHLD') do
      if @running
        died = pids.select {|pid| Process.waitpid(pid, Process::WNOHANG) rescue 0}
        died.each do |pid|
          logger.info "process #{pid} died, starting a new one"
          idx       = pids.index(pid)
          pids[idx] = run(server, idx)
        end
      end
    end

    signals =  %w(INT TERM QUIT)
    signals << %q(HUP) unless start_command

    signals.each do |signal|
      Signal.trap(signal) do
        @running = false
        logger.info "caught #{signal}, closing time for the bakery -- no more pastries!"
        stop_workers(signal)
        FileUtils.rm_f([pidfile, socket.to_s])
        Kernel.exit!
      end
    end

    Signal.trap('HUP') { graceful_restart(server) } if start_command
    Process.waitall rescue nil
  end

  def graceful_restart server
    @running = false
    logger.info "caught SIGHUP, restarting gracefully"

    FileUtils.mv pidfile, "#{pidfile}.old"

    pair = UNIXSocket.pair
    data = Socket::AncillaryData.unix_rights(server)
    pid  = fork do
      mesg, addr, rflags, *controls = pair[0].recvmsg(scm_rights: true)
      ENV['PASTRY_FD'] = controls.first.unix_rights[0].fileno.to_s
      pair.each(&:close)
      Kernel.exec(start_command)
    end

    pair[1].sendmsg "*", 0, nil, data
    pair.each(&:close)

    # TODO signal parent that all is good and the new master is good to roll on its own ?
    #      1. the new master failed to start
    #      2. something in the after_fork bit crapped out
    #      3. something else in the new code barfs during request
    #
    # A way to do this is provide pastry with a test route to hit after spawning the new master.
    Process.detach(pid)

    begin
      Timeout.timeout(timeout) { sleep 0.5 until File.exists?(pidfile) }
    rescue Timeout::Error => e
      Process.kill('TERM', pid) rescue nil
      logger.error "new master failed to spawn within #{timeout} secs, check logs"
      @running = true
      FileUtils.mv "#{pidfile}.old", pidfile
    else
      # finish exiting requests
      stop_workers('HUP')
      server.close
      FileUtils.rm_f "#{pidfile}.old"
      Kernel.exit
    end
  end

  def stop_workers signal
    logger.info "stopping workers"
    pids.each {|pid| Process.kill(signal, pid) rescue nil}
    return if signal == 'KILL'

    logger.info "waiting up to #{timeout} seconds"
    begin
      Timeout.timeout(timeout) do
        alive = pids
        until alive.empty?
          sleep 0.1
          alive = pids.reject {|pid| Process.waitpid(pid, Process::WNOHANG) rescue 0}
        end
      end
    rescue Timeout::Error => e
      logger.info "killing stray pastry chefs with butcher knife (SIGKILL)"
      pids.each {|pid| Process.kill('KILL', pid) rescue nil}
    end

    logger.info "all stop - ok"
  end

  def run server, worker
    fork do
      @after_fork && @after_fork.call(Process.pid, worker)
      $0 = "#{name ? "%s worker" % name : "pastry chef"} #{worker} (started: #{Time.now})"
      EM.epoll
      EM.set_descriptor_table_size(max_connections)
      EM.run { Backend.new.start(server) }
    end
  end

  module PastryServer
    attr_accessor :app
  end

  class Backend < Thin::Backends::Base
    def start server
      @stopping = false
      @running  = true
      @server   = server

      trap_signals!
      @signature = EM.attach_server_socket(server, Thin::Connection, &method(:initialize_connection))
    end

    def trap_signals!
      # ignore SIGCHLD, can be overriden by app.
      Signal.trap('CHLD', 'IGNORE')

      # close connections and stop gracefully
      Signal.trap('HUP') do
        stop
        EM.add_periodic_timer(1) { Kernel.exit! if @connections.empty? }
      end

      # die die, too bad
      %w(INT QUIT TERM).each {|signal| Signal.trap(signal) { stop!; Kernel.exit! }}
    end

    def disconnect
      EM.stop_server(@signature)
    end
  end # Backend
end # Pastry
