# Copied over rails_min by test/insitu/integration_test.rb. Boots the app and sends the
# requests in DRIVE_PATHS (comma separated) through Rack::MockRequest.
require "./config/environment"
require "rack/mock"
s = Rack::MockRequest.new(Rails.application)
ENV.fetch("DRIVE_PATHS", "").split(",").each do |p|
  r = s.get(p)
  $stderr.puts "#{p} #{r.status}"
end
