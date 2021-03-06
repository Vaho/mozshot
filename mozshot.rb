#!/usr/bin/env ruby
# 
# MozShot - Web site thumbnail service by gtkmozembed.
#
# Copyright (C) 2005 Tatsuki Sugiura <sugi@nemui.org>
# Released under the License same as Ruby.
#
# 
# This was based on MozSnapshooter written by Mirko Maischberger.
#   http://mirko.lilik.it/Ruby-GNOME2/moz-snapshooter.rb
#
# Origianl idea by Andrew McCall - <andrew at textux.com>
#   http://www.hackdiary.com/archives/000055.html
#
# And I refered many similar implementations. Thanks for all!
# 

begin
  require 'timestamp'
rescue LoadError
  # ignore
end
require 'gtkmozembed'
require 'thread'
require 'timeout'

class MozShot
  class InternalError < StandardError; end
  def initialize(useropt = {})
    if ENV['MOZILLA_FIVE_HOME']
       Gtk::MozEmbed.set_comp_path(ENV['MOZILLA_FIVE_HOME'])
    end
    @opt = { :mozprofdir => "#{ENV['HOME']}/.mozilla/mozshot",
             :winsize => [800, 800], :imgsize => [],
	     :timeout => 30, :imgformat => "png",
	     :keepratio => true, :shot_timeouted => false,
	     :retry => 0 }
    @opt.merge! useropt
    @window = nil
    @moz    = nil
    @mutex  = Hash.new {|h, k| h[k] = Mutex.new }
    if File.directory? "#{opt[:mozprofdir]}/default"
      @mozprof = "proc-#{$$}"
      puts "Using profile #{@mozprof}"
      require 'fileutils'
      begin
        FileUtils.cp_r "#{opt[:mozprofdir]}/default",
          "#{opt[:mozprofdir]}/#{@mozprof}"
      rescue Errno::EEXIST
        # ignore.... HMmmmmmmmmmmm............
      end
      begin
        File.unlink "#{opt[:mozprofdir]}/#{@mozprof}/lock"
      rescue Errno::ENOENT
        # ignore
      end
      # Signal trap will not works...?
      trap(:INT, "FileUtils.rm_rf('#{opt[:mozprofdir]}/#{@mozprof}')".untaint )
      trap(:QUIT, "FileUtils.rm_rf('#{opt[:mozprofdir]}/#{@mozprof}')".untaint )
      trap(:TERM, "FileUtils.rm_rf('#{opt[:mozprofdir]}/#{@mozprof}')".untaint )
      trap(:ABRT, "FileUtils.rm_rf('#{opt[:mozprofdir]}/#{@mozprof}')".untaint )
    else
      @mozprof = 'default'
    end
    Gtk.init
    Gtk::MozEmbed.set_profile_path opt[:mozprofdir], @mozprof
    @gtkthread = Thread.new { Gtk.main }
  end
  attr_accessor :opt, :gtkthread, :mozprof

  def join
    @gtkthread.join
  end

  def renew_mozwin(useropt = {})
    topt = opt.dup.merge! useropt
    @mutex[:mozwin].synchronize {
      unless @moz && @window
        w = Gtk::Window.new
        w.title = "MozShot -- Initalized"
        w.decorated = false
        w.has_frame = false
        w.border_width = 0
        m = Gtk::MozEmbed.new
        m.chrome_mask = Gtk::MozEmbed::ALLCHROME
        w << m
        @moz.nil? or @moz.destroy
        @window.nil? or @window.destroy
        @window = w
        @moz    = m
      end
    }
    @window.show_all
    @window.move(0,0)
    @window.resize(topt[:winsize][0], topt[:winsize][1])
  end

  def moz_load_url(url, useropt = {})
    shotopt = opt.dup.merge! useropt
    q = Queue.new
    @mutex[:load].synchronize {
      renew_mozwin(shotopt)
      @moz.stop_load
      sig_handle_net   = set_sig_handler("net_stop", q)
      sig_handle_title = set_sig_handler("title", q)

      begin
        puts "Loading: #{url}, opt: #{shotopt.inspect}"
        @moz.location = url

        timeout(shotopt[:timeout]){
	  sigs = Hash.new
          while !(sigs["net_stop"] && sigs["title"])
	    sigs[q.pop] = true
	  end
          puts "Load Done."
        }
      rescue Timeout::Error
        puts "Load Timeouted."
        # TODO
        Gtk::Window.toplevels.each { |w|
          # I can't close modal dialog....
          w.modal? and raise InternalError,
            "MozShot gone to wrong state. pelease restart process..."
        }
	if shotopt[:retry].to_i > 0
	  puts "timeouted. retring (remain #{shotopt[:retry]})"
	  shotopt[:retry] -= 1
	  q.clear
	  retry
	elsif shotopt[:shot_timeouted]
          puts "option :shot_timeouted is set, forceing screenshot..."
	else
          raise
	end
      end
      @moz.signal_handler_disconnect(sig_handle_net)
      @moz.signal_handler_disconnect(sig_handle_title)
    }
  end

  def screenshot_file(uri, filename, useropt = {})
    File.open(filename, "w") {|f|
      f << screenshot(uri, useropt)
    }
    filename
  end

  def screenshot(url, useropt = {})
    shotopt = opt.dup.merge! useropt
    pixbuf = nil
    @mutex[:shot].synchronize {
      moz_load_url(url, shotopt)
      sleep 0.2
      pixbuf = getpixbuf(@moz.window, shotopt)
    }

    if shotopt[:imgsize] && !shotopt[:imgsize].empty? &&
        shotopt[:imgsize] != shotopt[:winsize]
      width, height = *shotopt[:imgsize]
      if shotopt[:keepratio]
        ratio = shotopt[:winsize][0].to_f / shotopt[:winsize][1]
        if width.to_i.zero? || !height.to_i.zero? && height * ratio < width
          width  = height * ratio
        elsif height.to_i.zero? || !width.to_i.zero? && width / ratio < height
          height = width / ratio
        end
      end
      pixbuf = pixbuf.scale(width, height, Gdk::Pixbuf::INTERP_HYPER)
    end
    buf = pixbuf.save_to_buffer(opt[:imgformat])
    pixbuf = nil
    buf
  end

  def set_sig_handler(signame, queue)
    !signame || signame.empty? and return nil
    @moz.signal_connect(signame) {
      begin
        Gtk::timeout_add(100) {
          queue.push signame
          false
        }
      rescue => e
        puts e.class, e.message, e.backtrace
      end
    }
  end

  def getpixbuf(gdkw, shotopt = {})
    x, y, width, height, depth = gdkw.geometry
    pb = Gdk::Pixbuf.from_drawable(nil, gdkw, 0, 0, width, height)
    #puts "new pixbuf: #{pb.inspect}"
    #GC.trace_object(pb)
    pb
  end

  def cleanup
    @moz and moz_load_url("about:blank")
    #GC.start
  end

  def shutdown
    Gtk.main_quit
    if @mozprof != 'default'
      FileUtils.rm_rf("#{opt[:mozprofdir]}/#{@mozprof}")
    end
    join
  end

  def ping
    @mutex[:shot].synchronize {
      true
    }
  end
end


if __FILE__ == $0
  $0 = "#{File.basename(__FILE__, '.rb') } #{ENV['DISPLAY']}"
  ms = MozShot.new

  if ARGV.length == 0 && !ENV["MOZSHOT_DAEMON_SOCK"]
    puts "Usage: $0 <URL> [outputfile (default='mozshot.png')]"
  elsif ENV["MOZSHOT_DAEMON_SOCK"]
    require 'drb'
    require 'rinda/rinda'
    sockpath = ms.mozprof == 'default' ? '' : "#{ms.opt[:mozprofdir]}/#{ms.mozprof}/drbsock"
    begin
      File.unlink sockpath
    rescue Errno::ENOENT
      # ignore
    end
    DRb.start_service("drbunix:#{sockpath}", ms)
    tsuri = ENV["MOZSHOT_DAEMON_SOCK"]
    #ts = Rinda::TupleSpaceProxy.new(DRbObject.new_with_uri(tsuri))
    ts = DRbObject.new_with_uri(tsuri)
    ms.renew_mozwin
    i = 0
    loop {
      puts "waiting for request..."
      req = ts.take [:req, nil, Symbol, Hash]
      ts.write [:stat, req[1], :accept, {:pid => $$, :display => ENV['DISPLAY'], :timestamp => Time.now}], 600
      puts "took request ##{i}: #{req.inspect}"

      ret = {:req => req[3], :server_signature => "#{$$}/#{ENV['DISPLAY']}@#{Socket.gethostname}" }
      def ret.merge(hash)
	self[:timestamp] = Time.now
	super
      end

      begin
        if req[2] == :shot_buf
          buf = ms.screenshot(req[3][:uri], req[3][:opt]||{})
	  buf or raise "[BUG] Unknown Error: screenshot() returned #{buf.inspect}"
          ts.write([:ret, req[1], :success, ret.merge(:image => buf)], 300)
        elsif req[2] == :shot_file
          filename = ms.screenshot_file(req[3][:uri], req[3][:filename],
                                        req[3][:opt]||{})
	  filename or raise "[BUG] Unknown Error: screenshot_file() returned #{filename.inspect}"
          ts.write [:ret, req[1], :success, ret.merge(:filename => filename)], 300
        #elsif req[2] == :shutdown
        #  ts.write [:ret, req[1], :accept, "going shutdown"]
        #  puts "shutdown request was accepted, going shutdown."
        #  break
        else
          raise "Unknown request"
        end
      rescue MozShot::InternalError => e
        ts.write [:ret, req[1], :error, ret.merge(:err => e)], 3600
        #raise e
	exit!
      rescue Timeout::Error, StandardError => e
        ts.write [:ret, req[1], :error, ret.merge(:err => e)], 3600
      end
      begin
        ts.take [:stat, req[1], nil, nil], 0
      rescue Rinda::RequestExpiredError
	# ignore
      end
      ms.cleanup
      STDOUT.flush
      i += 1
      if i > 60
        puts "max request exceeded, exitting..."
	$stdout.flush
	DRb.stop_service
	#Thread.new{ sleep 3; puts "shutdown timeouted!"; exit! }
        #break
	ms.shutdown # Hmmm....
	exit!
      end
    }
  else
    ms.screenshot_file ARGV[0], (ARGV[1]|| "mozshot.png")
  end
  ms.shutdown
end

# vim: set sw=2:
# vim: set sts=2:
