// SL 2020-04-28
// DoomChip!
//
// References:
// - "DooM black book" by Fabien Sanglard
// - "DooM unofficial specs" http://www.gamers.org/dhs/helpdocs/dmsp1666.html
//
// TODO: 
// cleanup
// optimize           : - buffer column drawing and do it in //
//                      - framebuffer transpose (reduce row activate/precharge!)
//                      - parallel game logic (dualport bram)

$$print('------< Compiling the DooM chip >------')
$$print('---< written in Silice by @sylefeb >---')

$$wad = 'doom1.wad'
$$level = 'E1M2'
$$dofile('pre_wad.lua')

$$dofile('pre_load_data.lua')
$$ -- dofile('pre_render_test.lua')

$$dofile('pre_do_textures.lua')
// writes down the code generated by pre_do_textures
$texturechip$ 

$$texfile_palette = palette_666
$include('../common/video_sdram_main.ice')

// fixed point precisions
$$FPl = 48 
$$FPw = 24
$$FPm = 12

$$div_width = FPl
$include('../common/divint_any.ice')
$$mul_width = FPw
$include('../common/mulint_any.ice')

$$if DE10NANO then
$$INTERACTIVE = 1
$include('keypad.ice')
$include('lcd_status.ice')
$$end

// -------------------------
// some circuitry for repetitive things

circuitry to_h(input iv,output ov)
{
  ov = 100 + (iv >>> 15);
}

circuitry bbox_ray(input ray_x,input ray_y,input ray_dx_m,input ray_dy_m,
                   input bbox_x_lw,input bbox_x_hi,input bbox_y_lw,input bbox_y_hi,
                   output couldhit)
{
  couldhit = 1;
  if (ray_x > bbox_x_hi && ray_dx_m > 0) {
    couldhit = 0;
  }
  if (ray_x < bbox_x_lw && ray_dx_m < 0) {
    couldhit = 0;
  }
  if (ray_y > bbox_y_hi && ray_dy_m > 0) {
    couldhit = 0;
  }
  if (ray_y < bbox_y_lw && ray_dy_m < 0) {
    couldhit = 0;
  }
}

// Writes a pixel in the framebuffer, calls the texture unit
circuitry writePixel(
   inout  sd,  input  fbuffer,
   input  pi,  input  pj,
   input  tu,  input  tv,
   input  tid, input  lit   
) {
  // initiate texture unit lookup (takes a few cycles)
  textures <- (tid,-tu,tv,lit);
  // wait for not busy
  while (sd.busy) { /*waiting*/ }
  // sync with texture unit
  (sd.data_in) <- textures;
  // wait for not busy  (may have been in between)
  while (sd.busy) { /*waiting*/ }
  // write!
  sd.addr       = {~fbuffer,21b0} | (pi >> 2) | ((199-pj) << 8);
  sd.wbyte_addr = pi & 3;
  sd.in_valid   = 1; // go ahead!
}

// -------------------------
// Main drawing algorithm

algorithm frame_drawer(
  sdio sd {
    output addr,
    output wbyte_addr,
    output rw,
    output data_in,
    output in_valid,
    input  data_out,
    input  busy,
    input  out_valid,
  },
  input  uint1  vsync,
  output uint1  fbuffer,
  output uint4  kpadC,
  input  uint4  kpadR,
  output uint8  led,
  output uint1  lcd_rs,
  output uint1  lcd_rw,
  output uint1  lcd_e,
  output uint8  lcd_d,  
) {

  // BRAMs for BSP tree
  bram uint64 bsp_nodes_coords[] = {
$$for _,n in ipairs(bspNodes) do
   $pack_bsp_node_coords(n)$, // dy=$n.dy$ dx=$n.dx$ y=$n.y$ x=$n.x$
$$end
  };
  
  bram uint32 bsp_nodes_children[] = {
$$for _,n in ipairs(bspNodes) do
   $pack_bsp_node_children(n)$, // lchild=$n.lchild$ rchild=$n.rchild$ 
$$end
  };  
  
  bram uint128 bsp_nodes_boxes[] = {
$$for _,n in ipairs(bspNodes) do
   $pack_bsp_node_children_box(n)$, // left: $n.lbx_lw$,$n.lbx_hi$,$n.lby_lw$,$n.lby_hi$ right: $n.rbx_lw$,$n.rbx_hi$,$n.rby_lw$,$n.rby_hi$
$$end
  };  
  
  // BRAMs for sectors
  bram uint32 bsp_secs[] = {
$$for _,s in ipairs(bspSectors) do
   $pack_bsp_sec(s)$,          // c_h=$s.c_h$ f_h=$s.f_h$
$$end
  };

  bram uint40 bsp_secs_flats[] = {
$$for i,s in ipairs(bspSectors) do
   $pack_bsp_sec_flats(s)$,  // $i-1$] lowlight=$s.lowlight$ special=$s.special$ light=$s.light$ c_T=$s.c_T$ f_T=$s.f_T$
$$end
  };     

  // BRAM for sub-sectors
  bram uint40 bsp_ssecs[] = {
$$for _,s in ipairs(bspSSectors) do
   $pack_bsp_ssec(s)$,         // parentsec=$s.parentsec$ start_seg=$s.start_seg$ num_segs=$s.num_segs$
$$end
  };
  
  // BRAMs for segments
  bram uint64 bsp_segs_coords[] = {
$$for _,s in ipairs(bspSegs) do
   $pack_bsp_seg_coords(s)$, // v1y=$s.v1y$ v1x=$s.v1x$ v0y=$s.v0y$ v0x=$s.v0x$ 
$$end
  };
  
  bram uint48 bsp_segs_tex_height[] = {
$$for i,s in ipairs(bspSegs) do
   $pack_bsp_seg_tex_height(s)$, // $i-1$] movableid=$s.movableid$ other_sec=$s.other_sec$ upr=$s.upr$ mid=$s.mid$ lwr=$s.lwr$
$$end
  };
  
  bram uint66 bsp_segs_texmapping[] = {
$$for i,s in ipairs(bspSegs) do
   $pack_bsp_seg_texmapping(s)$, // $i-1$] unpegged U$s.upper_unpegged$ L$s.lower_unpegged$ segsqlen/32=$s.segsqlen$ yoff=$s.yoff$ xoff=$s.xoff$ seglen=$s.seglen$ 
$$end
  };  
  
  // BRAM for movables
  bram uint52 bsp_movables[] = { 
   52h0, // first record is not used
$$for i,m in ipairs(bspMovables) do
   $pack_movable(m)$, // $i-1$] sec=$m.sec$ downh=$m.downh$ uph=$m.uph$
$$end
  };  
$$if #bspMovables > 255 then error('more than 255 movables!') end
  uint8 num_bsp_movables = $1 + #bspMovables$;
  
  // BRAM for demo path
  bram uint64 demo_path[] = {
$$for _,s in ipairs(demo_path) do
   $pack_demo_path(s)$, // angle=$s.angle$ z=$s.z$ y=$s.y$ x=$s.x$
$$end
  };
  uint16 demo_path_len = $#demo_path$;
  
  // BRAM for floor/ceiling texturing ( 1/y table )
  bram int$FPw$ inv_y[101]={
    1, // 0: unused
$$for hscr=1,100 do
    $round((1<<(FPm))/hscr)$,
$$end
  };

  // BRAM for sine/cosine, could be made 1/4 of size, was lazy!
$$ sin_tbl = {}
$$ max_sin = ((2^FPm)-1)
$$for i=0,1023 do
$$   sin_tbl[i]        = round(max_sin*math.sin(2*math.pi*(i+0.5)/4096))
$$   sin_tbl[1024 + i] = round(math.sqrt(max_sin*max_sin - sin_tbl[i]*sin_tbl[i]))
$$   sin_tbl[2048 + i] = - sin_tbl[i]
$$   sin_tbl[2048 + 1024 + i] = - sin_tbl[1024 + i]
$$end
$$--for i=0,2047 do
$$--   print('sanity check: ' .. (math.sqrt(sin_tbl[i]*sin_tbl[i]+sin_tbl[i+1024]*sin_tbl[i+1024])))
$$--end

  bram int$FPm+1$ sin_m[4096] = {
$$for i=0,4095 do
    $sin_tbl[i]$,
$$end
  };

  // BRAM for x coord to angle
$$function col_to_x(i)
$$  return (320/2-(i+0.5))*3/320
$$end
  
  bram int13 coltoalpha[320] = {
$$for i=0,319 do
    $round(math.atan(col_to_x(i)) * (2^12) / (2*math.pi))$,
$$end
  };
  
  // BRAM for column to x coord
  bram int13 coltox[320] = {
$$for i=0,319 do
    $round(col_to_x(i)*256)$,
$$end
  };
  
  texturechip textures;

  uint16   queue[64] = {};
  uint9    queue_ptr = 0;

  uint1    vsync_filtered = 0;
  
  int$FPw$ cosview_m  = 0;
  int$FPw$ sinview_m  = 0;
  int16    viewangle  = $player_start_a$;
  int16    colangle   = 0;

  int16    time     = 0;
  int16    frame    = 0;
  int16    ray_z    = 40;
  int16    target_z = 40;
  int16    ray_x    = $player_start_x$;
  int16    ray_y    = $player_start_y$;
  int$FPw$ ray_dx_m = 0;
  int$FPw$ ray_dy_m = 0;
  int16    lx       = 0;
  int16    ly       = 0;
  int16    ldx      = 0;
  int16    ldy      = 0;
  int16    ndx      = 0;
  int16    ndy      = 0;
  int16    col_rx   = 0;
  int16    col_ry   = 0;
  int16    dx       = 0;
  int16    dy       = 0;
  int$FPw$ csl      = 0;
  int$FPw$ csr      = 0;
  int16    v0x      = 0;
  int16    v0y      = 0;
  int16    v1x      = 0;
  int16    v1y      = 0;
  int16    d0x      = 0;
  int16    d0y      = 0;
  int16    d1x      = 0;
  int16    d1y      = 0;
  int$FPl$ cs0_h    = 0;
  int$FPl$ cs1_h    = 0;
  int$FPl$ x0_h     = 0;
  int$FPl$ y0_h     = 0; // larger to hold FPm x FPm
  int$FPl$ x1_h     = 0;
  int$FPl$ y1_h     = 0; // larger to hold FPm x FPm
  int$FPl$ d_h      = 0;
  int$FPl$ l_h      = 0;
  int$FPw$ gu_m     = 0;
  int$FPw$ gv_m     = 0;
  int$FPw$ tr_gu_m  = 0;
  int$FPw$ tr_gv_m  = 0;
  int$FPw$ invd_h   = 0;
  int$FPw$ interp_m = 0;
  int16    tmp1     = 0;
  int16    tmp2     = 0;
  int16    tmp3     = 0;
  int$FPw$ tmp1_m   = 0;
  int$FPw$ tmp2_m   = 0;
  int$FPl$ tmp1_h   = 0; // larger to hold FPm x FPm
  int$FPl$ tmp2_h   = 0; // larger to hold FPm x FPm
  int$FPw$ tmp3_h   = 0;
  int16    h        = 0;
  int16    sec_f_h  = 0;
  int16    sec_c_h  = 0;
  int16    sec_f_o  = 0;
  int16    sec_c_o  = 0;
  int$FPw$ sec_f_h_w = 0;
  int$FPw$ sec_c_h_w = 0;
  int$FPw$ sec_f_o_w = 0;
  int$FPw$ sec_c_o_w = 0;
  int$FPw$ f_h      = 0;
  int$FPw$ c_h      = 0;
  int$FPw$ f_o      = 0;
  int$FPw$ c_o      = 0;
  int$FPw$ tex_v    = 0;
  int16    tc_u     = 0;
  int16    tc_v     = 0;
  int16    tmp_u    = 0;
  int16    tmp_v    = 0;
  int16    xoff     = 0;
  int16    yoff     = 0;
  uint8    texid    = 0;
  uint8    tmpid    = 0;
  uint8    seclight = 0;
  int$FPw$ light    = 0;
  int$FPw$ atten    = 0;
   
  div$FPl$ divl;
  int$FPl$ num      = 0;
  int$FPl$ den      = 0;
  mul$FPw$ mull;
  int$FPw$ mula     = 0;
  int$FPw$ mulb     = 0;
  int$FPl$ mulr     = 0;
 
  uint16   rchild    = 0;
  uint16   lchild    = 0;
  int16    bbox_x_lw = 0;
  int16    bbox_x_hi = 0;
  int16    bbox_y_lw = 0;
  int16    bbox_y_hi = 0;
  uint1    couldhit  = 0;

  int10    top = 200;
  int10    btm = 1;
  uint10   c   = 0;
  int10    j   = 0;
  uint8    palidx = 0;
  uint9    s   = 0;  
  uint16   n   = 0;
  
  uint52   movabledata = 0;
  uint1    active = 0;
  uint1    has_switch = 0;
  
  uint1    viewsector = 1;
  uint1    walkable   = 1;
  uint1    onesided   = 1;
  uint1    colliding  = 0;
  uint8    onmovable  = 0;
  uint1    movableseg = 0;
  
  uint16   kpressed   = 0;
  uint6    kpressblind = 0;
  
  uint12   rand = 3137;
  
  int16    debug0 = 0;
  int16    debug1 = 0;
  int16    debug2 = 0;
  int16    debug3 = 0;

$$if DE10NANO then
  keypad     kpad(kpadC :> kpadC, kpadR <: kpadR, pressed :> kpressed); 
  lcd_status status(<:auto:>, posx <: ray_x, posy <: ray_y, posz <: ray_z, posa <: viewangle );
$$end
  
  vsync_filtered ::= vsync;

  sd.in_valid := 0; // maintain low (pulses high when needed)
  
  sd.rw = 1;        // sdram write

  fbuffer = 0;
  
  // brams in read mode
  bsp_nodes_coords   .wenable = 0;
  bsp_nodes_children .wenable = 0;
  bsp_nodes_boxes    .wenable = 0;
  bsp_secs           .wenable = 0;
  bsp_secs_flats     .wenable = 0;
  bsp_ssecs          .wenable = 0;  
  bsp_segs_coords    .wenable = 0;
  bsp_segs_tex_height.wenable = 0;
  bsp_segs_texmapping.wenable = 0;
  bsp_movables       .wenable = 0;
  demo_path          .wenable = 0;
  inv_y              .wenable = 0;  
  sin_m              .wenable = 0;
  coltoalpha         .wenable = 0;
  coltox             .wenable = 0;
  
  while (1) {
    
    // update position
$$if not INTERACTIVE then
  ray_x     = demo_path.rdata[ 0,16];
  ray_y     = demo_path.rdata[16,16];
  ray_z     = demo_path.rdata[32,16];    
  viewangle = demo_path.rdata[48,16];
$$end
    
    col_rx = ray_x;
    col_ry = ray_y;
    
    // get cos/sin view
    sin_m.addr = (viewangle) & 4095;
++:
    sinview_m  = sin_m.rdata;
    sin_m.addr = (viewangle + 1024) & 4095;
++:
    cosview_m  = sin_m.rdata;

    // ----------------------------------------------
    // raycast columns
    c = 0;    
    while (c < 320) { 
      
      coltoalpha.addr = c;
      coltox    .addr = c;
++:
      colangle   = (viewangle + coltoalpha.rdata);

      // get ray dx/dy
      sin_m.addr = (colangle) & 4095;
++:    
      ray_dy_m   = sin_m.rdata;
      sin_m.addr = (colangle + 1024) & 4095;
++:    
      ray_dx_m   = sin_m.rdata;

      // set sin table addr to get cos(alpha)
      sin_m.addr = (coltoalpha.rdata + 1024) & 4095;
      
      top = 199;
      btm = 0;
      
      // init recursion
      queue[queue_ptr] = $root$;
      queue_ptr = 1;

      // let's rock!
      while (queue_ptr > 0) {
      
        queue_ptr = queue_ptr-1;
        n         = queue[queue_ptr];
        bsp_nodes_coords  .addr = n;
        bsp_nodes_children.addr = n;
        bsp_nodes_boxes   .addr = n;
++:
        if (n[15,1] == 0) {
        
          // internal node reached
          lx  = bsp_nodes_coords.rdata[0 ,16];
          ly  = bsp_nodes_coords.rdata[16,16];
          ldx = bsp_nodes_coords.rdata[32,16];
          ldy = bsp_nodes_coords.rdata[48,16];
          
          couldhit = 0;
          // which side are we on?
          dx   = ray_x - lx;
          dy   = ray_y - ly;
          csl  = (dx * ldy);
          csr  = (dy * ldx);
          if (csr > csl) {
            // front
            queue[queue_ptr  ] = bsp_nodes_children.rdata[ 0,16];
            bbox_x_lw          = bsp_nodes_boxes   .rdata[ 64,16];
            bbox_x_hi          = bsp_nodes_boxes   .rdata[ 80,16];
            bbox_y_lw          = bsp_nodes_boxes   .rdata[ 96,16];
            bbox_y_hi          = bsp_nodes_boxes   .rdata[112,16];
            (couldhit)         = bbox_ray(ray_x,ray_y,ray_dx_m,ray_dy_m,
                                          bbox_x_lw,bbox_x_hi,bbox_y_lw,bbox_y_hi);
            if (couldhit) {
              queue[queue_ptr+1] = bsp_nodes_children.rdata[16,16];
            }
          } else {
            // back
            queue[queue_ptr  ] = bsp_nodes_children.rdata[16,16];
            bbox_x_lw          = bsp_nodes_boxes   .rdata[  0,16];
            bbox_x_hi          = bsp_nodes_boxes   .rdata[ 16,16];
            bbox_y_lw          = bsp_nodes_boxes   .rdata[ 32,16];
            bbox_y_hi          = bsp_nodes_boxes   .rdata[ 48,16];
            (couldhit)         = bbox_ray(ray_x,ray_y,ray_dx_m,ray_dy_m,
                                          bbox_x_lw,bbox_x_hi,bbox_y_lw,bbox_y_hi);
            if (couldhit) {
              queue[queue_ptr+1] = bsp_nodes_children.rdata[ 0,16];          
            }
          }
          queue_ptr = queue_ptr + 1 + couldhit;
          
        } else {
          
          // sub-sector reached
          bsp_ssecs      .addr = n[0,14];
++:       
          bsp_secs       .addr = bsp_ssecs.rdata[24,16];
          bsp_secs_flats .addr = bsp_ssecs.rdata[24,16];
++:          
          // light level in sector
          switch (bsp_secs_flats.rdata[24,8]) {
            case 1: { // random off
              if (rand < 256) {
                seclight = bsp_secs_flats.rdata[32,8]; // off (lowlight)
              } else {
                seclight = bsp_secs_flats.rdata[16,8]; // on (sector light)
              }            
            }
            case 2: { // flash fast
              if ( (((time)>>4)&3) == 0 ) {
                seclight = bsp_secs_flats.rdata[16,8];
              } else {
                seclight = bsp_secs_flats.rdata[32,8];
              }            
            }
            case 3: { // flash slow
              if ( (((time)>>5)&3) == 0 ) {
                seclight = bsp_secs_flats.rdata[16,8];
              } else {
                seclight = bsp_secs_flats.rdata[32,8];
              }            
            }
            case 12: { // flash fast
              if ( (((time)>>4)&3) == 0 ) {
                seclight = bsp_secs_flats.rdata[16,8];
              } else {
                seclight = bsp_secs_flats.rdata[32,8];
              }            
            }
            case 13: { // flash slow
              if ( (((time)>>5)&3) == 0 ) {
                seclight = bsp_secs_flats.rdata[16,8];
              } else {
                seclight = bsp_secs_flats.rdata[32,8];
              }            
            }
            case 8: { // oscillates (to improve)
              if ( (((time)>>5)&1) == 0) {
                seclight = bsp_secs_flats.rdata[32,8];
              } else {
                seclight = bsp_secs_flats.rdata[16,8];
              }            
            }
            default: {
              seclight = bsp_secs_flats.rdata[16,8];
            }
          }
          
          // render column segments
          s = 0;
          while (s < bsp_ssecs.rdata[0,8]) {
            // get segment data
            bsp_segs_coords.addr      = bsp_ssecs.rdata[8,16] + s;
            bsp_segs_tex_height.addr  = bsp_ssecs.rdata[8,16] + s;
            bsp_segs_texmapping.addr  = bsp_ssecs.rdata[8,16] + s;
            // sector info (changes in loop)
            bsp_secs.addr             = bsp_ssecs.rdata[24,16];
++:
            // prepare movable data (if any)
            bsp_movables.addr         = bsp_segs_tex_height.rdata[40,8];
            // segment endpoints
            v0x = bsp_segs_coords.rdata[ 0,16];
            v0y = bsp_segs_coords.rdata[16,16];
            v1x = bsp_segs_coords.rdata[32,16];
            v1y = bsp_segs_coords.rdata[48,16];
            // check for intersection
            d0x = v0x - ray_x;
            d0y = v0y - ray_y;
            d1x = v1x - ray_x;
            d1y = v1y - ray_y;
++:
            cs0_h = (d0y * ray_dx_m - d0x * ray_dy_m);
            cs1_h = (d1y * ray_dx_m - d1x * ray_dy_m);
++:            
            if ((cs0_h<0 && cs1_h>=0) || (cs1_h<0 && cs0_h>=0)) {
            
              // compute distance        
              y0_h   =  (  d0x * ray_dx_m + d0y * ray_dy_m );
              y1_h   =  (  d1x * ray_dx_m + d1y * ray_dy_m );
++:
              x0_h   =  cs0_h;
              x1_h   =  cs1_h;

              // d  = y0 + (y0 - y1) * x0 / (x1 - x0)        
              num    = x0_h <<< $FPm$;
              den    = (x1_h - x0_h);
              (interp_m) <- divl <- (num,den);              

              // d_h   = y0_h + (((y0_h - y1_h) >>> $FPm$) * interp_m);
              mula   = (y0_h - y1_h);
              mulb   = interp_m;
              (mulr) <- mull <- (mula,mulb);
              d_h    = y0_h + (mulr >>> $FPm$);
++:
              if (d_h > $1<<(FPm+1)$) { // check distance sign, with margin to stay away from 0

                // hit!
                // -> correct to perpendicular distance ( * cos(alpha) )
                num     = $FPl$d$(1<<(2*FPm+FPw-2))$;
                den     = d_h * sin_m.rdata;
++:
                // -> compute inverse distance
                (invd_h) <- divl <- (num,den); // (2^(FPw-2)) / d
                d_h     = den >>> $FPm+4$; // record corrected distance for tex. mapping
                // -> get floor/ceiling heights 
                // NOTE: signed, so always read in same width!
                tmp1    = bsp_secs.rdata[0,16];  // floor height 
                sec_f_h = tmp1 - ray_z;
                tmp1    = bsp_secs.rdata[16,16]; // ceiling height
                sec_c_h = tmp1 - ray_z;                  
++:
                tmp1_h  = (sec_f_h * invd_h);     // h / d
                tmp2_h  = (sec_c_h * invd_h);     // h / d
++:
                // obtain projected heights
                (f_h) = to_h(tmp1_h);
                (c_h) = to_h(tmp2_h);
++:
                // clamp to top/bottom, shift for texturing
                sec_f_h_w = -1;
                if (btm > f_h) {
                  sec_f_h_w = - ((btm - f_h) * d_h); // offset texturing
                  f_h       = btm;
                } else { if (top < f_h) {
                  sec_f_h_w = - ((f_h - top) * d_h); // offset texturing
                  f_h       = top;
                } }
++:                
                sec_c_h_w = 0;
                if (btm > c_h) {
                  sec_c_h_w = ((btm - c_h) * d_h); // offset texturing
                  c_h       = btm;
                } else { if (top < c_h) {
                  sec_c_h_w = ((c_h - top) * d_h); // offset texturing
                  c_h       = top;
                } }
                
                // prepare sector data for other sector (if any)
                bsp_secs.addr = bsp_segs_tex_height.rdata[24,8];
                
                // draw floor
                texid = bsp_secs_flats.rdata[0,8];
                inv_y.addr = 100 - btm;
                while (btm < f_h) {
                  gv_m = (-sec_f_h)  * inv_y.rdata;
                  gu_m = (coltox.rdata * gv_m) >>> 8;                  
                  // NOTE: distance is gv_m>>4  (matches d_h if d_h shifted with FPw-1)                  
++: // relax timing
                  // transform plane coordinates
                  tr_gu_m = ((gu_m * cosview_m + gv_m * sinview_m) >>> $FPm$) + (ray_y<<<5);
                  tr_gv_m = ((gv_m * cosview_m - gu_m * sinview_m) >>> $FPm$) + (ray_x<<<5);
++: // relax timing
                  // light
                  tmp2_m = (gv_m>>8) - 15;
                  if (tmp2_m > 7) {
                    atten = 7;
                  } else {
                    atten = tmp2_m;
                  }                  
                  tmp1_m = seclight + atten;
                  if (tmp1_m > 31) {
                    light = 31;
                  } else { if (tmp1_m>=0){
                    light = tmp1_m;
                  } else {
                    light = 0;
                  } }
                  // write pixel
                  tmp_u = (tr_gv_m>>5);
                  tmp_v = (tr_gu_m>>5);
                  (sd)  = writePixel(sd,fbuffer,c,btm,tmp_u,tmp_v,texid,light);
                  btm   = btm + 1;
                  inv_y.addr = 100 - btm;
                }
                
                // draw ceiling
                texid = bsp_secs_flats.rdata[8,8];
                if (texid > 0 || (bsp_segs_tex_height.rdata[16,8] != 0)) {  // draw sky if upper texture present
                  inv_y.addr = top - 100;                
                  while (top > c_h) {
                    gv_m = (sec_c_h)   * inv_y.rdata;
                    gu_m = (coltox.rdata * gv_m) >>> 8;
++: // relax timing                  
                    // transform plane coordinates
                    tr_gu_m = ((gu_m * cosview_m + gv_m * sinview_m) >>> $FPm$) + (ray_y<<<5);
                    tr_gv_m = ((gv_m * cosview_m - gu_m * sinview_m) >>> $FPm$) + (ray_x<<<5);
++: // relax timing
                    // light
                    tmp2_m = (gv_m>>8) - 15;
                    if (tmp2_m > 7) {
                      atten = 7;
                    } else {
                      atten = tmp2_m;
                    }                  
                    tmp1_m = seclight + atten;
                    if (tmp1_m > 31) {
                      light = 31;
                    } else { if (tmp1_m>=0){
                      light = tmp1_m;
                    } else {
                      light = 0;
                    } }
                    // write pixel
                    tmp_u = (tr_gv_m>>5);
                    tmp_v = (tr_gu_m>>5);
                    (sd)  = writePixel(sd,fbuffer,c,top,tmp_u,tmp_v,texid,light);
                    top   = top - 1;
                    inv_y.addr = top - 100;
                  }
                }

                // tex coord u
                yoff   = bsp_segs_texmapping.rdata[32,16];
                xoff   = bsp_segs_texmapping.rdata[16,16];
                tc_u   = ((bsp_segs_texmapping.rdata[0,16] * interp_m) >> $FPm$) + xoff;

                // light
                tmp2_m = (d_h>>$FPm-1$) - 15;
                if (tmp2_m > 7) {
                  atten = 7;
                } else {
                  atten = tmp2_m;
                }                  
                tmp1_m = seclight + atten;
                if (tmp1_m > 31) {
                  light = 31;
                } else { if (tmp1_m>=0){
                  light = tmp1_m;
                } else {
                  light = 0;
                } }
                
++: // relax timing             

                // lower part?                
                if (bsp_segs_tex_height.rdata[0,8] != 0) {
                
                  texid     = bsp_segs_tex_height.rdata[0,8];
                  // if switch, possibly change texture
                  (has_switch) = is_switch(texid);
                  if (has_switch && bsp_segs_tex_height.rdata[40,8] != 0) {
                    // check movable status
                    if (bsp_movables.rdata[50,1] == 0) {
                      // use ON texture
                      texid = bsp_segs_tex_height.rdata[0,8] + 1; 
                    }
                  }
                  
                  tmp1      = bsp_secs.rdata[0,16]; // other sector floor height
                  sec_f_o   = tmp1 - ray_z;
++:
                  tmp1_h    = (sec_f_o * invd_h);
++:
                  sec_f_o_w = 0;
                  (f_o)     = to_h(tmp1_h);
                  if (btm > f_o) {
                    sec_f_o_w = ((btm - f_o) * d_h); // offset texturing
                    f_o       = btm;
                  } else { if (top < f_o) {
                    sec_f_o_w = ((f_o - top) * d_h); // offset texturing
                    f_o       = top;
                  } }
++:
                  if (bsp_segs_texmapping.rdata[64,1] == 0) {
                    // normal
                    tex_v   = (sec_f_o_w);
                  } else {
                    // lower unpegged                   
                    tex_v   = (sec_c_h_w) + ((c_h - f_o) * d_h);
                  }
                  j       = f_o;
                  while (j >= btm) {
                    tc_v   = tex_v >> $FPm-1+4$;
                    tmp_u  = tc_u;
                    tmp_v  = tc_v + yoff;
                    (sd)   = writePixel(sd,fbuffer,c,j,tmp_u,tmp_v,texid,light);
                    j      = j - 1;
                    tex_v  = tex_v + (d_h);
                  } 
                  btm = f_o;
                }
                
                // upper part?
                if ( (bsp_segs_tex_height.rdata[16,8] != 0) // upper texture present
                ||   (bsp_secs_flats.rdata[8,8] == 0 && bsp_segs_tex_height.rdata[8,8] != 0) // or opaque with sky above
                ) {
                  texid     = bsp_segs_tex_height.rdata[16,8];
                  
                  tmp1      = bsp_secs.rdata[16,16]; // other sector ceiling height                 
                  sec_c_o   = tmp1 - ray_z;
++:
                  tmp1_h    = (sec_c_o * invd_h);
++:
                  if (bsp_segs_texmapping.rdata[65,1] == 0) {
                    // normal
                    sec_c_o_w = -1;
                    (c_o)     = to_h(tmp1_h);
                    if (btm > c_o) {
                      sec_c_o_w = - ((btm - c_o) * d_h); // offset texturing
                      c_o       = btm;
                    } else { if (top < c_o) {
                      sec_c_o_w = - ((c_o - top) * d_h); // offset texturing
                      c_o       = top;
                    } }
                    tex_v   = (sec_c_o_w);
                    j       = c_o;
                    while (j <= top) {
                      tc_v   = tex_v >>> $FPm-1+4$;
                      tmp_u  = tc_u;
                      tmp_v  = tc_v + yoff;
                      (sd)   = writePixel(sd,fbuffer,c,j,tmp_u,tmp_v,texid,light);
                      j      = j + 1;
                      tex_v  = tex_v - (d_h);
                    }
                    top = c_o;
                  } else {
                    // upper unpegged
                    (c_o)     = to_h(tmp1_h);
                    if (btm > c_o) {
                      c_o       = btm;
                    } else { if (top < c_o) {
                      c_o       = top;
                    } }
                    tex_v   = (sec_c_h_w);
                    j       = top;
                    while (j >= c_o) {
                      tc_v   = tex_v >>> $FPm-1+4$;
                      tmp_u  = tc_u;
                      tmp_v  = tc_v + yoff;
                      (sd)   = writePixel(sd,fbuffer,c,j,tmp_u,tmp_v,texid,light);
                      j      = j - 1;
                      tex_v  = tex_v + (d_h);
                    }
                    top = c_o;                    
                  }
                }
                
                // opaque wall
                if (bsp_segs_tex_height.rdata[8,8] != 0) {
                
                  texid = bsp_segs_tex_height.rdata[8,8];
                  // if switch, possibly change texture
                  (has_switch) = is_switch(texid);
                  if (has_switch && bsp_segs_tex_height.rdata[40,8] != 0) {
                    // check movable status
                    if (bsp_movables.rdata[50,1] == 0) {
                      // use ON texture
                      texid = bsp_segs_tex_height.rdata[8,8] + 1; 
                    }
                  }
                  
                  if (bsp_segs_texmapping.rdata[64,1] == 0) {
                    // normal
                    tex_v   = (sec_c_h_w);
                    j       = c_h;
                    while (j >= f_h) {
                      tc_v   = tex_v >> $FPm-1+4$;
                      tmp_u  = tc_u;
                      tmp_v  = tc_v + yoff;
                      (sd)   = writePixel(sd,fbuffer,c,j,tmp_u,tmp_v,texid,light);
                      j      = j - 1;   
                      tex_v  = tex_v + (d_h);
                    }
                  } else {
                    // lower unpegged
                    tex_v   = (sec_f_h_w);
                    j       = f_h;
                    while (j <= c_h) {
                      tc_v   = tex_v >> $FPm-1+4$;
                      tmp_u  = tc_u;
                      tmp_v  = tc_v + yoff;
                      (sd)   = writePixel(sd,fbuffer,c,j,tmp_u,tmp_v,texid,light);
                      j      = j + 1;   
                      tex_v  = tex_v - (d_h);
                    }                    
                  }
                  // close column
                  top = btm;
                }
                
                if (top <= btm) { // column completed
                  // flush queue to stop
                  queue_ptr = 0;
                  break;                
                }
                
              }
            }
            // next segment
            s = s + 1;            
          }
        }
      }
      // next column    
      c = c + 1;
    }

    // ----------------------------------------------
    // collisions
$$if INTERACTIVE then    
    viewsector = 1;
    colliding  = 0;  
    onmovable  = 0;    
    // init recursion
    queue[queue_ptr] = $root$;
    queue_ptr  = 1;
    while (queue_ptr > 0) {    
      queue_ptr = queue_ptr-1;
      n         = queue[queue_ptr];
      bsp_nodes_coords  .addr = n;
      bsp_nodes_children.addr = n;
++:
      if (n[15,1] == 0) {      
        // internal node reached
        lx  = bsp_nodes_coords.rdata[0 ,16];
        ly  = bsp_nodes_coords.rdata[16,16];
        ldx = bsp_nodes_coords.rdata[32,16];
        ldy = bsp_nodes_coords.rdata[48,16];        
        // which side are we on?
        dx   = ray_x - lx;
        dy   = ray_y - ly;
        csl  = (dx * ldy);
        csr  = (dy * ldx);
        if (csr > csl) {
          // front
          queue[queue_ptr  ] = bsp_nodes_children.rdata[ 0,16];
          queue[queue_ptr+1] = bsp_nodes_children.rdata[16,16];
        } else {
          queue[queue_ptr  ] = bsp_nodes_children.rdata[16,16];
          queue[queue_ptr+1] = bsp_nodes_children.rdata[ 0,16];          
        }
        queue_ptr = queue_ptr + 2;            
      } else {        
        // sub-sector reached
        bsp_ssecs    .addr = n[0,14];
        // while here, track z        
        if (viewsector) { // done only once on first column
++:       
          bsp_secs   .addr = bsp_ssecs.rdata[24,16];
++:       
          target_z   = bsp_secs.rdata[0,16] + 40; // floor height + eye level
          viewsector = 0;
        }  
        // collision detection
        s = 0;
        while (s < bsp_ssecs.rdata[0,8]) {
          // get segment data
          bsp_segs_coords.addr      = bsp_ssecs.rdata[8,16] + s;
          bsp_segs_tex_height.addr  = bsp_ssecs.rdata[8,16] + s;
          bsp_segs_texmapping.addr  = bsp_ssecs.rdata[8,16] + s;
++:
          // prepare movable data (if any)
          bsp_movables.addr         = bsp_segs_tex_height.rdata[40,8];
          // prepare sector data for other sector (if any)
          bsp_secs.addr = bsp_segs_tex_height.rdata[24,8];
++:       
          // determine the type of segment (can we walk across, is it a movable?)
          walkable   = 1;
          movableseg = 0;
          onesided   = 0;
          if (bsp_segs_tex_height.rdata[8,8] != 0) { // opaque wall
            walkable = 0;
            onesided = 1;
          } else { // here we assume all walls without a middle section are two sided
            // other sector floor height
            tmp1      = bsp_secs.rdata[0,16];
            // other sector ceiling height
            tmp2      = bsp_secs.rdata[16,16];
            // walkable?
            if (ray_z < tmp1 || ray_z > tmp2) {
              walkable = 0;
            }
          }
          // movable?
          if (bsp_segs_tex_height.rdata[40,8] != 0) {  
            movableseg = 1;
          }
          if ((walkable == 0) || (movableseg == 1)) {
            // segment endpoints
            v0x = bsp_segs_coords.rdata[ 0,16];
            v0y = bsp_segs_coords.rdata[16,16];
            v1x = bsp_segs_coords.rdata[32,16];
            v1y = bsp_segs_coords.rdata[48,16];
            // segment vector
            d0x = col_rx - v0x;
            d0y = col_ry - v0y;
            // orthogonal distance to wall segment
            // (segment is v1 - v0)
            ldx    = v1x - v0x;
            ldy    = v1y - v0y;
            ndx    = - ldy; // ndx,ndy is orthogonal to v1 - v0
            ndy    =   ldx;
            // dot products
            l_h    = ldx * d0x + ldy * d0y;
            d_h    = ndx * d0x + ndy * d0y;
  ++:           
            if (onesided == 0 || d_h < 0) { // one sided only stops if d_h < 0
              if (d_h < 0) {
                tmp1_h = - d_h;
              } else {
                tmp1_h = d_h;
              }
              tmp2_h = (bsp_segs_texmapping.rdata[ 0,16] << 4) + (bsp_segs_texmapping.rdata[ 0,16] << 1); // seglen * (16 + 2)
              tmp3_h = bsp_segs_texmapping.rdata[48,16] << 5; // segsqlen
              // close to movable seg?
              if (movableseg == 1) {
                //          vvv  detect from further away
                if (((tmp1_h>>2) < tmp2_h) && (l_h > 0) && l_h < (tmp3_h)) {
                  onmovable  = bsp_movables.addr;
                }
              }
              if (walkable == 0) {
                // close to the wall?              vv margin to prevent going in between convex corners
                if ( (tmp1_h < tmp2_h) && (l_h > - 32) && l_h < (tmp3_h + 32) ) { 
                  colliding = 1;
                  //// DEBUG
                  debug1    = movableseg;
                  debug2    = bsp_movables.addr;
                  debug3    = bsp_ssecs.rdata[8,16] + s;
                  // decollision,  pos = pos + (d.n) * n
    ++:  // relax timing
                  if (d_h < 0) {
                    num    =  - ((tmp2_h - tmp1_h) << $FPm$);
                  } else {
                    num    =    ((tmp2_h - tmp1_h) << $FPm$);
                  }
                  den    = bsp_segs_texmapping.rdata[0,16];                  
    ++:  // relax timing
                  (tmp1_h) <- divl <- (num,den);
                  num    = tmp1_h * ndx;
                  (tmp2_h) <- divl <- (num,den);
                  col_rx = col_rx + (tmp2_h >>> $FPm$);
                  num    = tmp1_h * ndy;
                  (tmp2_h) <- divl <- (num,den);
                  col_ry = col_ry + (tmp2_h >>> $FPm$);
                }
              }
            }
          }
          s = s + 1;
        } 
      }
    }
$$end

    // ----------------------------------------------
    // motion movables
    bsp_movables.wenable = 0;
    bsp_movables.addr    = 1; // skip first (id=0 tags 'not a movable')
    while (bsp_movables.addr < num_bsp_movables) {
      if (bsp_movables.rdata[51,1]) { // active?
        
        ///// DEBUG
        debug0 = bsp_movables.addr;
        
        active = 1;
        // read sector
        bsp_secs    .wenable = 0;
        bsp_secs    .addr    = bsp_movables.rdata[32,16];
++:
        // floor or ceiling
        if (bsp_movables.rdata[48,1]) { 
          tmp1 = bsp_secs.rdata[0,16];
        } else {
          tmp1 = bsp_secs.rdata[16,16];
        }
        // direction
        if (bsp_movables.rdata[50,1] == 0) {
          // up
          tmp2 = bsp_movables.rdata[0,16]; // uph
          if (tmp1 < tmp2) {
            tmp3 = tmp1 + 1;
          } else {
            tmp3 = tmp1;
            active = 0;
          }
        } else {
          // down
          tmp2 = bsp_movables.rdata[16,16]; // downh
          if (tmp1 > tmp2) {
            tmp3 = tmp1 - 1;
          } else {
            tmp3 = tmp1;
            active = 0;
          }
        }
        // write back sector
        bsp_secs.wdata = bsp_secs.rdata;
        if (bsp_movables.rdata[48,1]) { 
          bsp_secs.wdata[0,16] = tmp3;
        } else {
          bsp_secs.wdata[16,16] = tmp3;
        }      
        bsp_secs.wenable = 1;
        // update movable if became inactive
        if (active == 0) {
          bsp_movables.wdata       = bsp_movables.rdata;
          bsp_movables.wdata[51,1] = active;
          bsp_movables.wenable     = 1;
++:          
          bsp_movables.wenable     = 0;
        }
      }
      // next
      bsp_movables.addr = bsp_movables.addr + 1;
    }
    bsp_secs.wenable = 0;
    
    // ----------------------------------------------
    // prepare next frame
    
    time  = time  + 1;
    if ((time & 3) == 0) {
      rand  = rand * 31421 + 6927;
    }
    
    frame = frame + 1;
$$if not INTERACTIVE then    
    if (frame >= demo_path_len) {
      // reset
      frame     = 0;
      viewangle = $player_start_a$;
      ray_x     = $(player_start_x)$;
      ray_y     = $(player_start_y)$;
    }    
    demo_path.addr = frame;
$$else
    //// DEBUG
    led[0,1] = colliding;
    if (onmovable != 0) {
      led[1,1] = 1;
    } else {
      led[1,1] = 0;
    }
    // viewangle
    if ((kpressed & 4) != 0) {
      viewangle   = viewangle + 12;
    } else {
    if ((kpressed & 8) != 0) {
      viewangle   = viewangle - 12;
    } }
    // forward motion
    if ((kpressed & 1) != 0) {
      ray_x   = col_rx + ((cosview_m) >>> $FPm-2$);
      ray_y   = col_ry + ((sinview_m) >>> $FPm-2$);
    } else {
    if ((kpressed & 2) != 0) {
      ray_x   = col_rx - ((cosview_m) >>> $FPm-2$);
      ray_y   = col_ry - ((sinview_m) >>> $FPm-2$);
    } }
    // manual movables
    if (kpressblind == 0) {
      if ((kpressed & 16) != 0) {        
        kpressblind = 1;
        // change movable direction
        bsp_movables.addr    = onmovable;
++:        
        movabledata          = bsp_movables.rdata;
        movabledata[50,1]    = ~bsp_movables.rdata[50,1];
        movabledata[51,1]    = 1; // activate
        bsp_movables.wdata   = movabledata;
        bsp_movables.wenable = 1;
++:        
        bsp_movables.wenable = 0;
      }
    } else {
      kpressblind = kpressblind + 1;
    }
    // up/down smooth motion
    if (ray_z < target_z) {
      if (ray_z + 3 < target_z) {
        ray_z = ray_z + 3;
      } else {
        ray_z = ray_z + 1;
      }
    } else { if (ray_z > target_z) {
      if (ray_z > target_z + 3) {
        ray_z = ray_z - 3;
      } else {
        ray_z = ray_z - 1;
      }
    } }
$$end  

    // ----------------------------------------------
    // end of frame

    // wait for vsync to end
    while (vsync_filtered == 0) {}
    
    // swap buffers
    fbuffer = ~fbuffer;
  }
}