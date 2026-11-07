c=->{Process.clock_gettime(Process::CLOCK_MONOTONIC)}
st=->(a){[a.sum/a.size*1000,a.min*1000]}
puts "A: probe無し sleep計測(ms) mean/min"
[0.1,0.05,0.03].each{|s| a=20.times.map{t=c.();sleep s;c.()-t}; printf("%.0f: %.2f / %.2f\n",s*1000,*st.(a))}
puts "B: probe有り (span vs 内部)"
D=__dir__
[100,50,30].each do |ms|
  sp=[];inn=[]
  20.times do
    File.delete("#{D}/in.txt") rescue nil
    system({"HAYATE_PROBE_OUT"=>"#{D}/o.json","INNER"=>"#{D}/in.txt"},"ruby","-r#{D}/../04_probe/probe.rb","-e","require '#{D}/d/s#{ms}.rb'")
    j=File.read("#{D}/o.json"); ev=j[/"events":(\[.*?\]),"specs"/m,1]
    e=eval(ev.gsub("null","nil")); w=7
    i=(0...e.size/w).find{|k| e[k*w+1].to_s.include?("s#{ms}.rb")}
    sp<<(e[i*w+4]-e[i*w+3]); inn<<File.read("#{D}/in.txt").split[1].to_f
  end
  printf("%d: span %.2f/%.2f  inner %.2f/%.2f  diff %.2f\n",ms,*st.(sp),*st.(inn),st.(sp)[0]-st.(inn)[0])
end
puts "C: empty span"
e2=[]
20.times do
  system({"HAYATE_PROBE_OUT"=>"#{D}/o.json"},"ruby","-r#{D}/../04_probe/probe.rb","-e","3.times{|i| load '#{D}/d/empty.rb'}; require '#{D}/d/empty.rb'")
  e=eval(File.read("#{D}/o.json")[/"events":(\[.*?\]),"specs"/m,1].gsub("null","nil"))
  (0...e.size/7).each{|k| e2<<[e[k*7],e[k*7+4]-e[k*7+3]]}
end
[0,2].each{|k| a=e2.select{_1[0]==k}.map{_1[1]}; printf("kind %d n=%d mean %.3f min %.3f ms\n",k,a.size,a.sum/a.size*1000,a.min*1000)}
