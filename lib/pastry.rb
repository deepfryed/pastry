require 'fileutils'
require 'logger'
require 'socket'
require 'thin'

class Pastry
  attr_reader :pool, :unix, :host, :port, :pidfile, :logfile, :daemon

  def initialize pool, app, options = {}
    @pool    = pool
    @app     = app
    @host    = options.fetch :host,       '127.0.0.1'
    @unix    = options.fetch :socket,     nil
    @logfile = options.fetch :logfile,    nil
    @daemon  = options.fetch :daemonize,  false
    @pidfile = options.fetch :pidfile,    '/tmp/pastry.pid'
    @name    = options.fetch :name,       nil

    @port    = options.fetch(:port,    3000).to_i
    @queue   = options.fetch(:queue,   1024).to_i
    @maxconn = options.fetch(:maxconn, 1024).to_i
    @timeout = options.fetch(:timeout,   30).to_i
  end

  def start
    ensure_not_running!
    Process.daemon if daemon

    if daemon || logfile
      STDOUT.reopen(logfile || '/tmp/pastry.log', 'a')
      STDERR.reopen(logfile || '/tmp/pastry.log', 'a')
      STDOUT.sync = true
      STDERR.sync = true
    end

    start!
  end

  def ensure_not_running!
    if File.exists?(pidfile) && pid = File.read(pidfile).to_i
      running = Process.kill(0, pid) rescue nil
      raise "already running with pid #{pid}" if running
      FileUtils.rm_f(pidfile)
    end
  end

  def create_pidfile
    File.open(pidfile, 'w') {|fh| fh.write(Process.pid)}
  end

  def name
    '%s master' % (@name || 'pastry')
  end

  def motd
    "starting #{name} with #{pool} minions listening on #{unix ? 'socket %s ' % unix : 'port %d' % port}"
  end

  def start!
    create_pidfile
    server = unix ? UNIXServer.new(unix) : TCPServer.new(host, port)

    server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true) unless unix
    server.fcntl(Fcntl::F_SETFL, server.fcntl(Fcntl::F_GETFL) | Fcntl::O_NONBLOCK)

    server.listen(@queue)
    server.extend(PastryServer)

    server.app = @app
    logger     = Logger.new(logfile || (daemon ? '/tmp/pastry.log' : $stdout), 0)

    logger.info motd

    $0         = name if @name
    @running   = true
    pids       = pool.times.map {|idx| run(server, idx) }

    Signal.trap('CHLD') do
      if @running
        died  = pids.reject {|pid| Process.kill(0, pid) rescue nil}
        died.each do |pid|
          logger.info "process #{pid} died, starting a new one"
          idx       = pids.index(pid)
          pids[idx] = run(server, idx)
        end
      end
    end

    %w(INT TERM HUP).each do |signal|
      Signal.trap(signal) do
        @running = false
        logger.info "caught #{signal}, closing time for the bakery -- no more pastries!"
        pids.each {|pid| Process.kill(signal, pid) rescue nil}
        Kernel.exit
      end
    end

    at_exit { FileUtils.rm_f(pidfile); FileUtils.rm_f(unix.to_s) }
    Process.waitall rescue nil
  end

  def run server, worker
    fork do
      $0 = "#{@name ? "%s worker" % @name : "pastry chef"} #{worker} (started: #{Time.now})"
      EM.epoll
      EM.set_descriptor_table_size(@maxconn)
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
      EM.attach_server_socket(server, Thin::Connection, &method(:initialize_connection))
    end

    def trap_signals!
      %w(INT TERM HUP CHLD).each do |signal|
        Signal.trap(signal) do
          @stopping = true
          @running  = false
          EM.stop
          Kernel.exit!
        end
      end
    end
  end # Backend
end # Pastry
