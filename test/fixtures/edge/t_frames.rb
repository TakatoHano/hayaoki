puts caller.count { |l| l =~ /in [`']((Kernel#)?(require|load))'/ }
