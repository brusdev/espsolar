---[[Home settings
wifi_ssid="Vodafone-brusnet"
wifi_pwd="dommiccargiafra"
wifi_ip="192.168.10.7"
wifi_netmask="255.255.255.0"
wifi_gateway="192.168.10.1"
--]]
--[[Work settings
wifi_ssid="Ditron-Internet-Access"
wifi_pwd="Ditron.wifi01"
wifi_ip="192.168.50.7"
wifi_netmask="255.255.255.0"
wifi_gateway="192.168.50.1"
--]]


thingspeak_channel_id="232899"
thingspeak_write_api_key="NHOKPWL6M9X4993X"

sleep_conversion=1*1000
sleep_duration=15*1000
sync_timeout=60*1000
run_timeout=30*1000
sntp_timeout=24*60*60*1000

rtc_time=0
rtc_begin=8
rtc_length=120

rtc_state=0
rtc_index=0
rtc_count=0
record_time=0
sntp_time=0

ds18b20 = require("ds18b20")

function boot()
  print("boot.begin")
  
  rtc_time=rtctime.get()
  
  --Check rtc memory.
  local rtc_init=rtcmem.read32(0)
  if (rtc_init==0x44695553) then
    rtc_state=rtcmem.read32(1)
    print("boot.rtc_state:"..rtc_state)
    rtc_index=rtcmem.read32(2)
    print("boot.rtc_index:"..rtc_index)
    rtc_count=rtcmem.read32(3)
    print("boot.rtc_count:"..rtc_count)
    record_time=rtcmem.read32(3)
    print("boot.record_time:"..record_time)
    sntp_time=rtcmem.read32(4)
    print("boot.sntp_time:"..sntp_time)
  end
  
  if rtc_state==1 and rtc_time~=0 and rtc_time-record_time<sync_timeout/1000 then
    ds18b20.convert(1)
    ds18b20.convert(2)
    rtc_state=2
    sleep(sleep_conversion, "end")
  elseif rtc_state==2 then
    push_record()
    rtc_state=2
    sleep(sleep_duration, "end")
  else
    ds18b20.convert(1)
    ds18b20.convert(2)
    
    print("boot.wifi")
    --Attivo la connessione wifi
    wifi.setmode(wifi.STATION)
    wifi.setphymode(wifi.PHYMODE_N)
    wifi.sta.eventMonReg(wifi.STA_GOTIP, on_wifi_got_ip)
    wifi.sta.eventMonStart()
    wifi.sta.config(wifi_ssid, wifi_pwd)
    wifi.sta.setip({ip=wifi_ip, netmask=wifi_netmask, gateway=wifi_gateway})
  end
end

function push_record()
  local head=rtc_index+rtc_begin
  print("push_record.head: "..head)
  local timestamp=rtctime.get()
  print("push_record.timestamp: "..timestamp)
  local temperatures=ds18b20.read(1)*0x100+ds18b20.read(2)
  print("push_record.temperatures: "..temperatures)
  local diagnostics=adc.readvdd33()*0x100+tmr.now()/1000
  print("push_record.diagnostics: "..diagnostics)
  record_time=rtctime.get()
  rtcmem.write32(head, timestamp)
  rtcmem.write32(head+1, temperatures)
  rtcmem.write32(head+2, diagnostics)
  
  rtc_index=(rtc_index+3)%rtc_length
  rtc_count=rtc_count+3
end

function peak_record()
  if rtc_count>0 then
    local tail=((rtc_index-rtc_count)%rtc_length)+rtc_begin
    print("peak_record.tail: "..tail)
    local timestamp=rtcmem.read32(tail)
    print("peak_record.timestamp: "..timestamp)
    local temperatures=rtcmem.read32(tail+1)
    print("peak_record.temperatures: "..temperatures)
    local diagnostics=rtcmem.read32(tail+2)
    print("peak_record.diagnostics: "..diagnostics)
    local etemp=ds18b20.decode(temperatures/0x100);
    local itemp=ds18b20.decode(bit.band(temperatures, 0xff));
    local record=
    "{\"created_at\":\""..timestamp.."\""..
    ",\"field1\":"..(etemp/10000).."."..(etemp%10000)..
    ",\"field2\":"..(itemp/10000).."."..(itemp%10000)..
    ",\"field3\":"..diagnostics/0x100..
    ",\"field4\":"..bit.band(diagnostics, 0xff).. "}"
    print("peak_record: " .. record)
    rtc_time=timestamp
    return record..string.rep(" ", 100 - string.len(record))
  else
    return nil
  end
end

function pop_record()
  rtc_count=rtc_count-3
end


function on_wifi_got_ip()
  print("on_wifi_got_ip.begin")
  wifi.sta.eventMonStop(1)
  
  if rtc_time~=0 and rtc_time-sntp_time<sntp_timeout/1000 then
    thingspeak_sync(function() sleep(sleep_duration, "end") end)
  else
    sntp.sync(nil, on_sntp_sync_success, on_sntp_sync_error)
  end
end

function on_sntp_sync_success()
  print("on_sntp_sync_success.begin")
  thingspeak_sync(function() sleep(sleep_duration, "end") end)
end

function on_sntp_sync_error()
  print("on_sntp_sync_error.begin")
  if rtc_time~=0 then
    thingspeak_sync(function() sleep(sleep_duration, "end") end)
  else
    sleep(sleep_duration, "end")
  end
end

function thingspeak_sync(callback)
  print("thingspeak_sync.begin")
  local thingspeak_socket_connected=false
  local thingspeak_socket=net.createConnection(net.TCP, 0)
    
  local function on_connection(socket)
    print("on_connection.begin")
    thingspeak_socket_connected=true
    
    local content = "{\"write_api_key\":\"" .. thingspeak_write_api_key .. "\", \"updates\":["
    local content_length=string.len(content) + (rtc_count / 3) * 100 + 2
    local data = "POST /channels/".. thingspeak_channel_id .. "/bulk_update.json HTTP/1.1\r\n" ..
      "HOST: api.thingspeak.com\r\n" ..
      "Content-Length: " ..content_length.. "\r\n" ..
      "Content-Type: application/json\r\n\r\n" .. content
        
    print("on_connection.send: " .. data)
    socket:send(data)
  end

  local function on_sent(socket)
    print("on_sent.begin")
    local data=nil
    print("on_sent.rtc_count: "..rtc_count)
    if rtc_count > 0 then
      data=peak_record()
      pop_record()
      print("on_sent.send: " .. data)
      socket:send(data)
      
      if rtc_count==0 then
        data="]}"
        print("on_sent.send: " .. data)
        socket:send(data)
      end
    end
  end
  
  local function on_receive(socket, data)
    print("on_receive.begin")
    print("on_receive.data: " .. data)
    if (string.find(data, "Status: 202 Accepted") ~= nil) then
      print("on_receive.success")
      sleep(sleep_duration, "run_timeout")
    end
    print("on_receive.socket::close(--)")
    --socket:close()
  end
  
  local function on_disconnection(socket)
    print("on_disconnection.begin")
    thingspeak_socket_connected=false
    callback()
  end
  
  thingspeak_socket:on("connection", on_connection)
  thingspeak_socket:on("disconnection", on_disconnection)
  thingspeak_socket:on("receive", on_receive)
  thingspeak_socket:on("sent", on_sent)
  
  push_record()
  
  print("thingspeak_sync.rtc_count: "..rtc_count)
  
  thingspeak_socket:connect(80, "api.thingspeak.com")
end

function sleep(duration, reason)
    print("sleep.begin")
    
    rtcmem.write32(0, 0x44695553)
    rtcmem.write32(1, rtc_state)
    rtcmem.write32(2, rtc_index)
    rtcmem.write32(3, rtc_count)
    rtcmem.write32(4, record_time)
    rtcmem.write32(5, sntp_time)
  
    print("sleep.duration: " .. duration)
    print("sleep.reason: " .. reason)
    wifi.setmode(wifi.NULLMODE)
    rtctime.dsleep(duration * 1000, 4)
end

--Verifico se stato disattivata l'esecuzione.
gpio.mode(3, gpio.INPUT, gpio.PULLUP)
if gpio.read(3) ~= 0 then
  boot()
  tmr.alarm(0, run_timeout, tmr.ALARM_SINGLE, function() sleep(sleep_duration, "run_timeout") end)
end
