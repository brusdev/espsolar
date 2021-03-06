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

--[[Debug settings
sleep_conversion=1*1000
sleep_duration=5*1000
run_timeout=30*1000
sent_timeout=60*1000
sntp_timeout=24*60*60*1000
--]]
---[[Run settings
sleep_conversion=1*1000
sleep_duration=5*60*1000
run_timeout=10*1000
sent_timeout=1*60*60*1000
sntp_timeout=24*60*60*1000
--]]

rtc_time=0
rtc_begin=14
rtc_length=114

queue_state=0
queue_head=0
queue_count=0
queue_sent=0
sent_time=0
sntp_time=0

ds18b20 = require("ds18b20")

function boot()
  print("boot.begin")
  
  rtc_time=rtctime.get()
  print("boot.rtc_time:"..rtc_time)
  
  if (rtc_time~=0) then
    local queue_data=rtcmem.read32(10)
    queue_state=bit.band(queue_data/0x1, 0xFF)
    print("boot.queue_state:"..queue_state)
    queue_head=bit.band(queue_data/0x100, 0xFF)
    print("boot.queue_head:"..queue_head)
    queue_count=bit.band(queue_data/0x10000, 0xFF)
    print("boot.queue_count:"..queue_count)
    queue_sent=queue_count
    print("boot.queue_sent:"..queue_sent)
    sent_time=rtcmem.read32(11)
    print("boot.sent_time:"..sent_time)
    sntp_time=rtcmem.read32(12)
    print("boot.sntp_time:"..sntp_time)
  end
  
  if queue_state==1 and rtc_time~=0 and rtc_time-sent_time<sent_timeout/1000 then
    ds18b20.convert(1)
    ds18b20.convert(2)
    queue_state=2
    sleep(sleep_conversion, "end")
  elseif queue_state==2 then
    push_record()
    queue_state=1
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
  local head=queue_head+rtc_begin
  print("push_record.head: "..head)
  local timestamp=rtc_time
  local temperatures=ds18b20.read(1)*0x10000+ds18b20.read(2)
  local diagnostics=adc.readvdd33()*0x10000+tmr.now()/1000
  
  rtcmem.write32(head, timestamp)
  rtcmem.write32(head+1, temperatures)
  rtcmem.write32(head+2, diagnostics)
  
  queue_head=(queue_head+3)%rtc_length
  queue_count=queue_count+3
  if (queue_count>rtc_length) then
    queue_count=rtc_length
  end
  queue_sent=queue_sent+3
  if (queue_sent>rtc_length) then
    queue_sent=rtc_length
  end
end

function pop_record()
  if queue_sent>0 then
    local tail=((queue_head-queue_sent)%rtc_length)+rtc_begin
    print("peak_record.tail: "..tail)
    local timestamp=rtcmem.read32(tail)
    local temperatures=rtcmem.read32(tail+1)
    local diagnostics=rtcmem.read32(tail+2)
    local etemp=ds18b20.decode(temperatures/0x10000);
    local itemp=ds18b20.decode(bit.band(temperatures, 0xFFFF));
    local record=
    "{\"created_at\":\""..timestamp.."\""..
    ",\"field1\":"..(etemp/10000).."."..(etemp%10000)..
    ",\"field2\":"..(itemp/10000).."."..(itemp%10000)..
    ",\"field3\":"..diagnostics/0x10000..
    ",\"field4\":"..bit.band(diagnostics, 0xFFFF).. "}"
    queue_sent=queue_sent-3
    return record..string.rep(" ", 100 - string.len(record))
  else
    return nil
  end
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
  rtc_time=rtctime.get()
  print("on_sntp_sync_success.rtc_time:"..rtc_time)
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
  local thingspeak_socket_sending=false
  local thingspeak_socket=net.createConnection(net.TCP, 0)
    
  local function on_connection(socket)
    print("on_connection.begin")
    thingspeak_socket_connected=true
    thingspeak_socket_sending=true
    
    local content = "{\"write_api_key\":\"" .. thingspeak_write_api_key .. "\", \"updates\":["
    local content_length=string.len(content) + (queue_count / 3) * 101 + 102
    local data = "POST /channels/".. thingspeak_channel_id .. "/bulk_update.json HTTP/1.1\r\n" ..
      "HOST: api.thingspeak.com\r\n" ..
      "Content-Length: " ..content_length.. "\r\n" ..
      "Content-Type: application/json\r\n\r\n" .. content
        
    --print("on_connection.send: " .. data)
    socket:send(data)
  end

  local function on_sent(socket)
    if (thingspeak_socket_sending) then
      print("on_sent.begin")
      local data=pop_record()
      
      if data==nil then
        push_record()
        data=pop_record()
        data=data.."]}"
        thingspeak_socket_sending=false
      else
        data=data..","
      end
      
      print("on_sent.send: " .. data)
      socket:send(data)
    end
  end
  
  local function on_receive(socket, data)
    print("on_receive.begin")
    --print("on_receive.data: " .. data)
    if (string.find(data, "Status: 202 Accepted") ~= nil) then
      print("on_receive.success")
      queue_state=1
      queue_count=0
      queue_head=0
      sent_time=rtc_time
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
  
  print("thingspeak_sync.queue_count: "..queue_count)
  
  thingspeak_socket:connect(80, "api.thingspeak.com")
end

function sleep(duration, reason)
    print("sleep.begin")
    
    local queue_data=queue_state*0x1+queue_head*0x100+queue_count*0x10000
    rtcmem.write32(10, queue_data)
    rtcmem.write32(11, sent_time)
    rtcmem.write32(12, sntp_time)
  
    print("sleep.duration: " .. duration)
    print("sleep.reason: " .. reason)
    print("sleep.now: " .. tmr.now())
    wifi.setmode(wifi.NULLMODE)
    rtctime.dsleep(duration * 1000, 4)
end

--Verifico se stato disattivata l'esecuzione.
gpio.mode(5, gpio.INPUT, gpio.PULLUP)
if gpio.read(5) ~= 0 then
  boot()
  tmr.alarm(0, run_timeout, tmr.ALARM_SINGLE, function() sleep(sleep_duration, "run_timeout") end)
end
