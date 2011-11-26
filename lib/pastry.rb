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
    @port    = options.fetch :port,       3000
    @unix    = options.fetch :socket,     nil
    @queue   = options.fetch :queue,      1024
    @logfile = options.fetch :logfile,    nil
    @daemon  = options.fetch :daemonize,  false
    @pidfile = options.fetch :pidfile,    '/tmp/pastry.pid'
    # TODO: validation
  end

  def start
    ensure_not_running!
    Process.daemon if daemon
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

  def motd
    "starting #{@app} pastry with #{pool} flakes listening on #{unix ? 'socket %s ' % unix : 'port %d' % port}"
  end

  def start!
    create_pidfile
    server = unix ? UnixServer.new(unix) : TCPServer.new(host, port)

    server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true) unless unix
    server.fcntl(Fcntl::F_SETFL, server.fcntl(Fcntl::F_GETFL) | Fcntl::O_NONBLOCK)

    server.listen(@queue)
    server.extend(PastryServer)

    @running   = true
    server.app = @app
    logger     = Logger.new(logfile || daemon ? '/tmp/pastry.log' : $stdout, 0)
    pids       = pool.times.map { run(server) }

    logger.info motd
    Signal.trap('CHLD') do
      unless @running
        died  = pids.reject {|pid| Process.kill(0, pid) rescue nil}
        pids -= died
        died.each do |pid|
          logger.info "process #{pid} died, starting a new one"
          pids << run(server)
        end
      end
    end

    at_exit { FileUtils.rm_f(pidfile) }

    %w(INT TERM HUP).each do |signal|
      Signal.trap(signal) do
        @running = false
        logger.info "caught #{signal}, closing time for the bakery -- no more pastries!"
        pids.each {|pid| Process.kill(signal, pid) }
        exit
      end
    end

    Process.waitall rescue nil
  end

  def run server
    fork { EM.run { Backend.new.start(server) } }
  end

  module PastryServer
    attr_accessor :app
  end

  class Backend < Thin::Backends::Base
    def start server
      @stopping = false
      @running  = true
      @server   = server

      config
      trap_signals!

      EM.attach_server_socket(server, Thin::Connection, &method(:initialize_connection))
    end

    def trap_signals!
      %w(INT TERM HUP CHLD).each do |signal|
        Signal.trap(signal) { exit }
      end
    end
  end # Backend
end # Pastry
