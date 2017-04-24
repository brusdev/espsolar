local ds18b20 = {}

function ds18b20.convert(pin)
  ow.setup(pin)
  ow.reset(pin)
  ow.skip(pin)
  ow.write(pin, 0x44, 1)
end

function ds18b20.read(pin)
  ow.setup(pin)
  ow.reset(pin)
  ow.skip(pin)
  ow.write(pin, 0xBE, 1)

  local data = string.char(ow.read(pin))
  for i = 1, 8 do
    data = data .. string.char(ow.read(pin))
  end
  crc = ow.crc8(string.sub(data,1,8))
  if (crc == data:byte(9)) then
    return data:byte(1)+data:byte(2)*0x100
  else
    return 0
  end
end

function ds18b20.decode(t)
  if (t > 32767) then
    t = t - 65536
  end
  t = t * 625
  return t
end

return ds18b20
