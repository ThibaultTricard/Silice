print('preparing textures')

if SIMULATION then
USE_BRAM = false -- RAM or ROM
SHRINK   = 1 -- 0 is original res, 1 half, 2 a quarter
else
USE_BRAM = false -- RAM or ROM
SHRINK   = 1 -- 0 is original res, 1 half, 2 a quarter
             -- synthesis is much fast at a quarter res, recommanded for testing
end

ALL_IN_ONE = false

-- -------------------------------------
-- helper functions
function texture_dim_pow2(dim)
  local pow2=0
  local tmp = dim
  while tmp > 1 do
    pow2 = pow2 + 1
    tmp  = (tmp>>1)
  end
  return pow2,(dim == (1<<pow2))
end

function shrink_tex(img)
  local w = #img[1]
  local h = #img
  local shi = {}
  for j = 1,h//2 do 
    shi[j] = {}
    for i = 1,w//2 do
      shi[j][i] = img[j*2][i*2]
    end
  end
  return shi
end

function update_palette(img,pal)
  local w = #img[1]
  local h = #img
  for j = 1,h do 
    for i = 1,w do
      local clr  = pal[1+img[j][i]]
      local pidx = inv_palette[clr]
      if not pidx then
        error('color not found')
      end
      img[j][i] = pidx - 1
    end
  end
  return img
end

-- -------------------------------------
-- get script path
path,_1,_2 = string.match(findfile('vga_doomchip.ice'), "(.-)([^\\/]-%.?([^%.\\/]*))$")

-- -------------------------------------
-- parse pnames
local in_pnames = assert(io.open(findfile('lumps/PNAMES.lump'), 'rb'))
local num_pnames = string.unpack('I4',in_pnames:read(4))
pnames={}
for p=1,num_pnames do
  local name = in_pnames:read(8):match("[%_-%a%d]+")
  pnames[p-1] = name
end
in_pnames:close()

-- -------------------------------------
-- parse texture defs
local in_texdefs = assert(io.open(findfile('lumps/TEXTURE1.lump'), 'rb'))
local imgcur = nil
local imgcur_w = 0
local imgcur_h = 0
local sz_read = 0
local num_texdefs = string.unpack('I4',in_texdefs:read(4))
local texdefs_seek={}
for i=1,num_texdefs do
  texdefs_seek[i] = string.unpack('I4',in_texdefs:read(4))
end
for i=1,num_texdefs do
  local name = in_texdefs:read(8):match("[%_-%a%d]+")
  in_texdefs:read(2) -- skip
  in_texdefs:read(2) -- skip
  local w = string.unpack('H',in_texdefs:read(2))
  local h = string.unpack('H',in_texdefs:read(2))
  in_texdefs:read(2) -- skip
  in_texdefs:read(2) -- skip
  -- start new
  print('wall texture ' .. name .. ' ' .. w .. 'x' .. h)
  imgcur = {}
  for j=1,h do
    imgcur[j] = {}
    for i=1,w do
      imgcur[j][i] = 0
    end
  end
  -- copy patches
  local npatches = string.unpack('H',in_texdefs:read(2))
  for p=1,npatches do
    local x   = string.unpack('h',in_texdefs:read(2))
    local y   = string.unpack('h',in_texdefs:read(2))
    local pid = string.unpack('H',in_texdefs:read(2))
    pname = nil
    if pnames[pid] then
      pname = pnames[pid]
      print('   patch "' .. pname .. '" id=' .. pid)
      print('     x:  ' .. x)
      print('     y:  ' .. y)
    end
    in_texdefs:read(2) -- skip
    in_texdefs:read(2) -- skip    
    if pname then
      print('   loading patch ' .. pname)
      local pimg = decode_patch_lump(path .. 'lumps/patches/' .. pname .. '.lump')
      local ph = #pimg
      local pw = #pimg[1]
      print('   patch is ' .. pw .. 'x' .. ph)
      for j=1,ph do
        for i=1,pw do
           if ((j+y) <= #imgcur) and ((i+x) <= #imgcur[1]) and (j+y) > 0 and (i+x) > 0 then
             if pimg[j][i] > -1 then -- -1 is transparent
               imgcur[math.floor(j+y)][math.floor(i+x)] = pimg[j][i]
             end
           end
        end
      end
      print('   copied.')    
    else
      error('cannot find patch ' .. pid)
    end
  end
  -- save  
  print('saving ' .. name .. ' ...')
  save_table_as_image_with_palette(imgcur,palette,path .. 'textures/assembled/' .. name .. '.tga')
  print('         ... done.')
end

-- -------------------------------------
-- produce code for the texture chip
print('generating texture chip code')
local code = assert(io.open(path .. 'texturechip.ice', 'w'))
code:write([[algorithm texturechip(
  input  uint8 texid,
  input  int9  iiu,
  input  int9  iiv,
  input  uint5 light,
  output uint8 palidx) {
  ]])
-- build bram and texture start address table
code:write('  uint8  u    = 0;\n')
code:write('  uint8  v    = 0;\n')
code:write('  int9   iu   = 0;\n')
code:write('  int9   iv   = 0;\n')
code:write('  int9   nv   = 0;\n')
code:write('  uint16 lit  = 0;\n')
code:write('  brom   uint8 colormap[] = {\n')
for _,cmap in ipairs(colormaps) do
  for _,cidx in ipairs(cmap) do
    code:write('8h'..string.format("%02x",cidx):sub(-2) .. ',')
  end
end
code:write('};\n')
texture_start_addr = 0
texture_start_addr_table = {}
if ALL_IN_ONE then
  if USE_BRAM then
    code:write('  bram uint8 textures[] = {\n')
  else
    code:write('  brom uint8 textures[] = {\n')
  end
end
for tex,nfo in pairs(texture_ids) do
  if tex ~= 'F_SKY1' then -- skip sky entirely
    -- load texture
    local texdata
    if nfo.type == 'wall' then
      texdata = get_image_as_table(path .. 'textures/assembled/' .. tex .. '.tga')
    else
      texdata = decode_flat_lump(path .. 'lumps/flats/' .. tex .. '.lump')
    end
    if SHRINK == 3 then
      texdata = shrink_tex(shrink_tex(shrink_tex(texdata)))
    elseif SHRINK == 2 then
      texdata = shrink_tex(shrink_tex(texdata))
    elseif SHRINK == 1 then
      texdata = shrink_tex(texdata)
    end  
    local texw = #texdata[1]
    local texh = #texdata
    texture_start_addr_table[tex] = texture_start_addr
    texture_start_addr = texture_start_addr + texw * texh
    -- data
    if not ALL_IN_ONE then
      if USE_BRAM then
        code:write('  bram uint8 texture_' .. tex .. '[] = {\n')
      else
        code:write('  brom uint8 texture_' .. tex .. '[] = {\n')
      end
    end
    for j=1,texh do
      for i=1,texw do
        code:write('8h'..string.format("%02x",texdata[j][i]):sub(-2) .. ',')
      end
    end
    if not ALL_IN_ONE then
      code:write('};\n')
    end
  end
end
if ALL_IN_ONE then
  code:write('};\n')
end

-- addressing
if SHRINK == 3 then
  code:write('  iu = iiu>>>3;\n')
  code:write('  iv = iiv>>>3;\n')
elseif SHRINK == 2 then
  code:write('  iu = iiu>>>2;\n')
  code:write('  iv = iiv>>>2;\n')
elseif SHRINK == 1 then
  code:write('  iu = iiu>>>1;\n')
  code:write('  iv = iiv>>>1;\n')
else
  code:write('  iu = iiu;\n')
  code:write('  iv = iiv;\n')
end
code:write('  switch (texid) {\n')
code:write('    default : { }\n')  
for tex,nfo in pairs(texture_ids) do
  if tex ~= 'F_SKY1' then -- skip sky entirely
    -- load texture
    local texdata
    if nfo.type == 'wall' then
      texdata = get_image_as_table(path .. 'textures/assembled/' .. tex .. '.tga')
    else
      texdata = decode_flat_lump(path .. 'lumps/flats/' .. tex .. '.lump')
    end
    if SHRINK == 3 then
      texdata = shrink_tex(shrink_tex(shrink_tex(texdata)))
    elseif SHRINK == 2 then
      texdata = shrink_tex(shrink_tex(texdata))
    elseif SHRINK == 1 then
      texdata = shrink_tex(texdata)
    end  
    local texw = #texdata[1]
    local texh = #texdata
    local texw_pow2,texw_perfect = texture_dim_pow2(texw)
    local texh_pow2,texh_perfect = texture_dim_pow2(texh)
    code:write('    case ' .. (nfo.id) .. ': {\n')
    code:write('       // ' .. tex .. ' ' .. texw .. 'x' .. texh .. '\n')
    if not texw_perfect then
      code:write('     if (iu > ' .. (3*texw) ..') {\n')
      code:write('       u = iu - ' .. (3*texw) .. ';\n')
      code:write('     } else {\n')
      code:write('       if (iu > ' .. (2*texw) ..') {\n')
      code:write('         u = iu - ' .. (2*texw) .. ';\n')
      code:write('       } else {\n')
      code:write('         if (iu > ' .. (texw) ..') {\n')
      code:write('           u = iu - ' .. (texw) .. ';\n')
      code:write('         } else {\n')
      code:write('           u = iu;\n')
      code:write('         }\n')
      code:write('       }\n')
      code:write('     }\n')
    end
    code:write('     if (iv > 0) { nv = iv; } else { nv = ' .. texh ..  ' + iv; } \n')
    if not texh_perfect then
      code:write('     if (nv > ' .. (3*texh) ..') {\n')
      code:write('       v = nv - ' .. (3*texh) .. ';\n')
      code:write('     } else {\n')
      code:write('       if (nv > ' .. (2*texh) ..') {\n')
      code:write('         v = nv - ' .. (2*texh) .. ';\n')
      code:write('       } else {\n')
      code:write('         if (nv > ' .. (texh) ..') {\n')
      code:write('           v = nv - ' .. (texh) .. ';\n')
      code:write('         } else {\n')
      code:write('           v = nv;\n')
      code:write('         }\n')
      code:write('       }\n')
      code:write('     }\n')
    else
      code:write('     v = nv; \n')
    end
    if ALL_IN_ONE then
      code:write('       textures.addr = ' .. texture_start_addr_table[tex] .. ' + ')
    else
      code:write('       texture_' .. tex .. '.addr = ')
    end
    if texw_perfect then
      code:write(' (iu&' .. (texw-1) .. ')')
    else
      code:write(' (u)')
    end
    if texh_perfect then
      code:write(' + ((v&' .. ((1<<texh_pow2)-1) .. ')')
    else
      code:write(' + ((v)')
    end
    if texw_perfect then
      code:write('<<' .. texw_pow2 .. ');\n')
    else
      code:write('*' .. texw .. ');\n')
    end
    code:write('    }\n')
  end
end
code:write('  }\n') -- switch

-- wait two cycles (seems required @100MHz, single one led to artifacts)
code:write('++:\n')
code:write('++:\n')

-- light
code:write('  lit = (light<<8);\n')
-- read data and query colormap
if ALL_IN_ONE then
  code:write('  colormap.addr = textures.rdata + lit;\n')
else
  code:write('  switch (texid) {\n')
  code:write('    default : { }\n')  
  code:write('    case 0  : { colormap.addr = 94; }\n')  
  for tex,nfo in pairs(texture_ids) do
    code:write('    case ' .. (nfo.id) .. ': {\n')
    if tex == 'F_SKY1' then -- special case for sky
      code:write('       colormap.addr = 94;\n')
    else
      code:write('       colormap.addr = texture_' .. tex .. '.rdata + lit;\n')
    end
    code:write('    }\n')
  end
  code:write('  }\n') 
end

-- wait one cycle
code:write('++:\n')

-- done with texture data
code:write('palidx = colormap.rdata;\n')
code:write('}\n')

-- now make a circuit to tell which ids are on/off switches
-- switch ON
code:write('circuitry is_switch_on(input texid,output is)\n')
code:write('{\n')
code:write('  switch (texid) {\n')
code:write('    default : { is = 0; }\n')  
for id,name in pairs(switch_on_ids) do
  code:write('    case ' .. id .. '  : { is = 1; }\n')  
end
code:write('  }\n') 
code:write('}\n')
-- switch OFF
code:write('circuitry is_switch_off(input texid,output is)\n')
code:write('{\n')
code:write('  switch (texid) {\n')
code:write('    default : { is = 0; }\n')  
for id,name in pairs(switch_off_ids) do
  code:write('    case ' .. id .. '  : { is = 1; }\n')  
end
code:write('  }\n') 
code:write('}\n')
-- switch ON or OFF
code:write('circuitry is_switch(input texid,output is)\n')
code:write('{\n')
code:write('  switch (texid) {\n')
code:write('    default : { is = 0; }\n')  
for id,name in pairs(switch_on_ids) do
  code:write('    case ' .. id .. '  : { is = 1; }\n')  
end
for id,name in pairs(switch_off_ids) do
  code:write('    case ' .. id .. '  : { is = 1; }\n')  
end
code:write('  }\n') 
code:write('}\n')

-- done
code:close()

-- now load file into string
local code = assert(io.open(path .. 'texturechip.ice', 'r'))
texturechip = code:read("*all")
code:close()

print('stored ' .. texture_start_addr .. ' texture bytes\n')
