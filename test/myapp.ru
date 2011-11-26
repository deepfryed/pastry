class MyApp
  def self.call req
    [200, {'Content-Type' => 'text/plain'}, ['hello world!', $/]]
  end
end

run MyApp
