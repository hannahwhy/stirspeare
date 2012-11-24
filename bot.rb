require 'celluloid'
require 'celluloid/io'
require 'fileutils'
require 'irb'
require 'yaml'

include FileUtils

CONFIG = YAML.load(File.read(File.expand_path('../config.yml', __FILE__)))

DATA_DIR = File.expand_path("../#{CONFIG['megahal_data_dir']}", __FILE__)
mkdir_p DATA_DIR

logio = File.open("#{DATA_DIR}/stirspeare.log", "a")
logio.sync = true
logger = ::Logger.new(logio)

Celluloid.logger = logger

# The MegaHAL interface.
class Megahal
  include Celluloid
  include Celluloid::Logger

  def initialize
    info "Starting MegaHAL: #{command}"

    start
  end

  def reply_to(string)
    string.sub!(/^#/, '')

    @io.write(string)
    @io.write("\n\n")

    lines = []

    loop do
      line = @io.readline.strip
      lines << line

      if line =~ /[^\w]$/
        break
      end
    end

    lines.join(' ')
  end

  def save
    @io.write("#SAVE\n\n")

    # #SAVE outputs a reply, so be sure to consume it
    ::IO.select([@io])
    resync
  end

  def quit
    @io.write("#QUIT\n\n")
  end

  def resync
    begin
      loop { @io.read_nonblock(128) }
    rescue ::IO::WaitReadable
      # hey, we're ok now
    end
  end

  def start
    @io = ::IO.popen(command, 'w+')

    # Startup outputs a reply, so be sure to consume it
    ::IO.select([@io])
    resync
  end

  def restart
    quit
    start
  end

  def command
    cmd = File.expand_path("../#{CONFIG['megahal_engine']}", __FILE__)
    options = "-b -p -d #{DATA_DIR}"

    "#{cmd} #{options}"
  end
end

# The IRC client.
class IrcClient
  include Celluloid::IO
  include Celluloid::Logger

  def initialize
    connect

    async.run
  end

  def connect
    @host = CONFIG['irc']['server']
    @port = CONFIG['irc']['port']
    @user = CONFIG['irc']['user']
    @nick = CONFIG['irc']['nick']
    @join = CONFIG['irc']['join']

    info "Connecting to #{@host}:#{@port}"

    @socket = TCPSocket.new(@host, @port)
    @running = true

    @socket.wait_writable

    info "Registering with username #{@user}, nick #{@nick}"

    @socket.write "USER #{@user} #{@user} #{@user} : #{@user}\n"
    @socket.write "NICK #{@nick}\n"
  end

  def quit
    @socket.write "QUIT :exited\n"
    @running = false
  end

  def join(channel)
    info "Joining #{channel}"
    @socket.write "JOIN :#{channel}\n"
  end

  def part(channel)
    info "Parting #{channel}"
    @socket.write "PART :#{channel}\n"
  end

  def run
    while @running
      @socket.wait_readable

      data = @socket.read.split("\n")
      
      data.each do |line|
        if line =~ /PING :(.+)/
          debug "Received PING, responding with #{$1}"
          @socket.write "PONG :#{$1}\n"
        end

        if line =~ /001.*Welcome/
          @join.each { |channel| join(channel) }
        end

        if line =~ /:([^!]+)!.+PRIVMSG ([^\s:]+) :#{Regexp.escape(@nick)}: (.*)/
          sender  = $1
          channel = $2
          message = $3

          info "<#{sender}!#{channel}> #{message}"
          megahal = Celluloid::Actor[:megahal].reply_to(message)
          response = "#{sender}: #{megahal}"
          info "Response: #{response}"

          @socket.write "PRIVMSG #{channel} :#{response}\n"
        end
      end
    end
  end
end

Megahal.supervise_as :megahal
IrcClient.supervise_as :client

def megahal
  Celluloid::Actor[:megahal]
end

def client
  Celluloid::Actor[:client]
end

at_exit do
  megahal.quit
  client.quit
end
  
# A command interface.
IRB.start
