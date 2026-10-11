versions = {}
Dir['../*.lic'].each do |path|
  file = File.basename(path)
  body = File.open("../#{file}", 'r').readlines.join('')
  body =~ /custom_require.call\((.+)\)/i
  reqs = Regexp.last_match(1) || ''
  reqs = "['#{reqs}']" if reqs =~ /^\w/
  name = file[0..-5]
  versions[name] = eval(reqs)
end

versions.keys.each do |file|
  v = {}
  todo = [versions[file]].flatten
  while (curr = todo.pop)
    raise "Cycle in #{file}" if curr == file
    v[curr] = true
    todo = (todo + versions[curr]).uniq - v.keys if versions[curr]
  end
end
