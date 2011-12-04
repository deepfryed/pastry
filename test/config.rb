before_fork do
  puts "before fork"
end

after_fork do |n, pid|
  puts "worker #{n} with pid #{pid}"
end
