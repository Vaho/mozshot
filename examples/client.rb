#!/usr/bin/ruby
#

require 'drb'
require 'rinda/rinda'

DRb.start_service('drbunix:')
ts = DRbObject.new_with_uri("drbunix:#{ENV['HOME']}/.mozilla/mozshot/drbsock")

ARGV.each_with_index {|uri, i|
  print "Sending request for #{uri}..."
  ts.write [:req, $$, :shot_file, {:uri => uri, :filename => "shot#{$$}-#{i}.png"}], Rinda::SimpleRenewer.new(30)
  puts "done."
  print "Waiting for result..."
  ret = ts.take [:ret, $$, nil, nil]
  if ret[2] == :success
    puts "done. screenshot was saved in #{ret[3][:filename]}"
  else
    puts "fail! #{ret[3]}"
  end
}
