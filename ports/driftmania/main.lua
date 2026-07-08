-- ==== GENERATED DATA BEGIN (tools/gen.js — do not edit by hand) ====
-- track A1 of Driftmania by maxbize (CC-BY-NC-SA 4.0), 30x30 chunks of
-- 3x3 tiles; layer-local chunk ids packed r|d<<5|p<<10; ckd 0=skip,
-- 1..15=solid color, 16+k=tile def k; masks: bit(x)=1 row bytes.
-- constants: DECB=23 PROPB=44 NCK=54 SPAWN=(312,264) dir=0.5 laps=3
local decb = 23
local propb = 44
local spawnx = 312
local spawny = 264
local spawndir = 0.5
local nlaps = 3
local mplat = 990
local mgold = 1080
local msilver = 1216
local mbronze = 1440
local ncp = 3
local cgrid = array(900)
local ckdt = array(54)
local ctiles = array(239)
local wallbit = array(540)
local tmi = array(128)
local tcls = array(12)
local tmask = array(96)
local wpk = array(128)
local bpk = array(256)
local cpx = array(3)
local cpy = array(3)
local cpdx = array(3)
local cpdy = array(3)
local cpl = array(3)
local div3 = array(96)
-- div3[i]*30 precomputed: the chunk-row stride multiply (cgrid is 30 wide)
-- appears 6× in the hot tile-lookup path (grass_at/collides via road_tile/
-- prop_tile + the wallnear pretest). div3[i] is an ARRAY read so the
-- compiler can't strength-reduce the *30 (it won't dup an index), and it
-- lowered to the generic mul8 every call — grass_at alone was ~11k cyc/frame.
-- A flat table turns each into one more index.
local div3x30 = array(96)
local cs_lut = array8(30)  -- (i*10)\3 — centiseconds for the race clock
-- chunk-decode byte LUTs for the asm track renderer (road + decal+decb)
local ckdl = array8(32)
local ckdl2 = array8(32)
local cprops = array8(48)
local ckf = 0              -- race clock: frames 0-29
local cks = 0              -- seconds 0-59
local ckm = 0              -- minutes

function gd_1()
 cgrid[138]=1024
 for i=139,143 do cgrid[i]=2048 end
 cgrid[144]=3072
 cgrid[168]=4096
 cgrid[169]=1
 cgrid[170]=2
 cgrid[171]=2
 cgrid[172]=2
 cgrid[173]=3
 cgrid[174]=4096
 cgrid[198]=4096
 cgrid[199]=4
 cgrid[200]=5
 cgrid[201]=38
 cgrid[202]=5
 cgrid[203]=7
 cgrid[204]=4096
 cgrid[228]=4096
 cgrid[229]=68
 cgrid[230]=104
 cgrid[231]=5257
 cgrid[232]=170
 cgrid[233]=7
 cgrid[234]=4096
 cgrid[258]=4096
 cgrid[259]=68
 cgrid[260]=7
 cgrid[261]=4096
 cgrid[262]=68
 cgrid[263]=7
 cgrid[264]=4096
 cgrid[276]=1024
 for i=277,287 do cgrid[i]=2048 end
 cgrid[288]=6347
 cgrid[289]=236
 cgrid[290]=7
 cgrid[291]=4096
 cgrid[292]=68
 cgrid[293]=7
 cgrid[294]=4096
 cgrid[306]=4096
 cgrid[307]=1
 for i=308,312 do cgrid[i]=2 end
 cgrid[313]=258
 for i=314,317 do cgrid[i]=2 end
 cgrid[318]=301
 cgrid[319]=5
 cgrid[320]=7
 cgrid[321]=4096
 cgrid[322]=4
 cgrid[323]=7
 cgrid[324]=4096
 cgrid[336]=4096
 cgrid[337]=4
 cgrid[338]=5
 cgrid[339]=334
 cgrid[340]=367
 cgrid[341]=367
 cgrid[342]=15
 cgrid[343]=271
 for i=344,349 do cgrid[i]=15 end
 cgrid[350]=16
 cgrid[351]=4096
 cgrid[352]=4
 cgrid[353]=7
 cgrid[354]=4096
 cgrid[366]=4096
 cgrid[367]=4
 cgrid[368]=104
 cgrid[369]=1425
 for i=370,380 do cgrid[i]=2048 end
 cgrid[381]=6347
 cgrid[382]=236
 cgrid[383]=7
 cgrid[384]=4096
 cgrid[396]=4096
 cgrid[397]=4
 cgrid[398]=7
 cgrid[399]=4096
 cgrid[400]=1
 for i=401,408 do cgrid[i]=2 end
 cgrid[409]=418
 cgrid[410]=418
 cgrid[411]=301
 cgrid[412]=453
 cgrid[413]=7
 cgrid[414]=4096
 cgrid[426]=4096
 cgrid[427]=4
 cgrid[428]=7
 cgrid[429]=4096
 cgrid[430]=4
 cgrid[431]=5
 cgrid[432]=334
 for i=433,442 do cgrid[i]=15 end
 cgrid[443]=496
 cgrid[444]=4096
 cgrid[456]=4096
 cgrid[457]=4
 cgrid[458]=7
 cgrid[459]=4096
 cgrid[460]=4
 cgrid[461]=104
 cgrid[462]=7569
 for i=463,473 do cgrid[i]=2048 end
 cgrid[474]=6144
 cgrid[486]=4096
 cgrid[487]=4
 cgrid[488]=7
 cgrid[489]=4096
 cgrid[490]=4
 cgrid[491]=530
 cgrid[492]=8755
 for i=493,497 do cgrid[i]=2048 end
 cgrid[498]=3072
 cgrid[516]=4096
 cgrid[517]=4
 cgrid[518]=7
 cgrid[519]=4096
 cgrid[520]=4
 cgrid[521]=5
 cgrid[522]=596
 cgrid[523]=418
 cgrid[524]=418
 cgrid[525]=2
 cgrid[526]=2
 cgrid[527]=3
 cgrid[528]=4096
 cgrid[546]=4096
 cgrid[547]=4
 cgrid[548]=7
 cgrid[549]=4096
 cgrid[550]=21
 for i=551,554 do cgrid[i]=15 end
 cgrid[555]=630
 cgrid[556]=5
 cgrid[557]=7
 cgrid[558]=4096
 cgrid[576]=4096
 cgrid[577]=4
 cgrid[578]=647
 cgrid[579]=9216
 for i=580,584 do cgrid[i]=2048 end
 cgrid[585]=3767
 cgrid[586]=170
 cgrid[587]=7
 cgrid[588]=4096
 cgrid[606]=4096
 cgrid[607]=4
 cgrid[608]=647
 cgrid[609]=4096
 cgrid[615]=4096
 cgrid[616]=68
 cgrid[617]=7
 cgrid[618]=4096
 cgrid[636]=4096
 cgrid[637]=4
 cgrid[638]=530
 cgrid[639]=10803
 for i=640,644 do cgrid[i]=2048 end
 cgrid[645]=6347
 cgrid[646]=236
 cgrid[647]=7
 cgrid[648]=4096
 cgrid[666]=4096
 cgrid[667]=4
 cgrid[668]=5
 cgrid[669]=596
 cgrid[670]=2
 cgrid[671]=2
 cgrid[672]=2
 cgrid[673]=418
 cgrid[674]=418
 cgrid[675]=301
 cgrid[676]=453
 cgrid[677]=7
 cgrid[678]=4096
 cgrid[696]=4096
 cgrid[697]=21
 for i=698,706 do cgrid[i]=15 end
 cgrid[707]=496
 cgrid[708]=4096
 cgrid[726]=10240
 for i=727,737 do cgrid[i]=2048 end
 cgrid[738]=6144
 ckdt[1]=16
 ckdt[2]=17
 ckdt[3]=18
 ckdt[4]=19
 ckdt[5]=261
 ckdt[6]=20
 ckdt[7]=21
 ckdt[8]=22
 ckdt[9]=23
 ckdt[10]=24
 ckdt[11]=25
 ckdt[12]=26
 ckdt[13]=27
 ckdt[14]=28
 ckdt[15]=29
end

function gd_2()
 ckdt[16]=30
 ckdt[17]=31
 ckdt[18]=32
 ckdt[19]=33
 ckdt[20]=34
 ckdt[21]=35
 ckdt[22]=36
 ckdt[23]=37
 ckdt[24]=38
 ckdt[25]=39
 ckdt[26]=40
 ckdt[27]=41
 ckdt[28]=42
 ckdt[29]=43
 ckdt[30]=44
 ckdt[31]=45
 ckdt[32]=46
 ckdt[33]=47
 ckdt[34]=48
 ckdt[35]=49
 ckdt[36]=50
 ckdt[37]=51
 ckdt[38]=52
 ckdt[39]=53
 ckdt[40]=54
 ckdt[41]=55
 ckdt[42]=56
 ckdt[43]=57
 ckdt[44]=58
 ckdt[45]=59
 ckdt[46]=60
 ckdt[47]=61
 ckdt[48]=62
 ckdt[49]=63
 ckdt[50]=64
 ckdt[51]=65
 ckdt[52]=66
 ckdt[53]=67
 ckdt[54]=68
 ctiles[1]=520
 ctiles[2]=1026
 ctiles[3]=257
 ctiles[4]=260
 ctiles[5]=513
 ctiles[6]=514
 ctiles[7]=257
 ctiles[8]=257
 ctiles[9]=257
 ctiles[10]=514
 ctiles[11]=263
 ctiles[12]=1281
 ctiles[13]=257
 ctiles[14]=1029
 ctiles[15]=257
 ctiles[16]=260
 ctiles[17]=1025
 for i=18,21 do ctiles[i]=257 end
 ctiles[22]=769
 ctiles[23]=257
 ctiles[24]=1281
 ctiles[25]=257
 ctiles[26]=261
 ctiles[27]=1281
 ctiles[28]=257
 ctiles[29]=257
 ctiles[30]=1281
 ctiles[31]=257
 ctiles[32]=2309
 ctiles[33]=1536
 ctiles[37]=257
 ctiles[38]=1025
 ctiles[39]=257
 ctiles[40]=260
 ctiles[41]=1
 ctiles[45]=2048
 ctiles[46]=260
 ctiles[47]=1025
 ctiles[48]=257
 ctiles[49]=257
 ctiles[50]=513
 ctiles[51]=258
 for i=52,57 do ctiles[i]=257 end
 ctiles[58]=769
 ctiles[59]=259
 ctiles[60]=257
 ctiles[61]=257
 ctiles[62]=769
 ctiles[63]=771
 ctiles[64]=257
 ctiles[65]=261
 ctiles[66]=1281
 ctiles[67]=771
 ctiles[68]=2313
 ctiles[73]=257
 ctiles[74]=261
 ctiles[75]=1281
 ctiles[76]=257
 ctiles[77]=1
 ctiles[80]=1792
 ctiles[82]=513
 ctiles[83]=258
 ctiles[84]=257
 ctiles[85]=257
 ctiles[86]=1025
 ctiles[87]=257
 ctiles[88]=260
 ctiles[89]=1537
 ctiles[90]=771
 ctiles[91]=257
 ctiles[92]=257
 ctiles[93]=257
 ctiles[94]=771
 ctiles[95]=1
 ctiles[96]=1536
 ctiles[103]=29440
 ctiles[104]=29184
 ctiles[106]=114
 ctiles[107]=29184
 ctiles[111]=29952
 ctiles[113]=25461
 ctiles[114]=25088
 ctiles[119]=29184
 ctiles[121]=114
 ctiles[126]=25344
 ctiles[127]=114
 ctiles[128]=29184
 ctiles[132]=10
 ctiles[133]=2560
 ctiles[135]=10
 ctiles[136]=29812
 ctiles[144]=29555
 ctiles[148]=29555
 ctiles[149]=25459
 ctiles[154]=29812
 ctiles[155]=116
 ctiles[158]=3840
 ctiles[160]=3840
 ctiles[162]=3840
 ctiles[163]=15
 ctiles[165]=15
 ctiles[168]=29952
 ctiles[170]=117
 ctiles[175]=98
 ctiles[177]=29812
 ctiles[184]=29555
 ctiles[186]=29952
 ctiles[188]=117
 ctiles[189]=29952
 ctiles[191]=98
 ctiles[197]=45
 ctiles[198]=15661
 ctiles[200]=15360
 ctiles[201]=15420
 ctiles[205]=43
 ctiles[206]=15104
 ctiles[207]=43
 ctiles[208]=11264
 ctiles[210]=44
 ctiles[211]=11264
 ctiles[214]=11264
 ctiles[216]=44
 ctiles[217]=15661
 ctiles[218]=15616
 ctiles[223]=11520
 ctiles[224]=60
 ctiles[225]=44
 ctiles[226]=11264
 ctiles[228]=15419
 ctiles[231]=44
 ctiles[232]=11776
 ctiles[233]=60
 ctiles[234]=44
 ctiles[235]=15104
 ctiles[236]=43
 ctiles[237]=15104
 wallbit[82]=-32
 wallbit[83]=63
 wallbit[88]=48
 wallbit[89]=96
 wallbit[94]=16
 wallbit[95]=64
 wallbit[100]=16
 wallbit[101]=64
 wallbit[106]=16
 wallbit[107]=64
 wallbit[112]=16
 wallbit[113]=64
 wallbit[118]=16
 wallbit[119]=64
 wallbit[124]=16
 wallbit[125]=64
 wallbit[130]=16
 wallbit[131]=64
 wallbit[136]=8208
 wallbit[137]=64
 wallbit[142]=8208
 wallbit[143]=64
 wallbit[148]=8208
 wallbit[149]=64
 wallbit[154]=8208
end

function gd_3()
 wallbit[155]=64
 wallbit[160]=8208
 wallbit[161]=64
 wallbit[166]=8216
 wallbit[167]=64
 wallbit[170]=-2
 wallbit[171]=-1
 wallbit[172]=8207
 wallbit[173]=64
 wallbit[176]=3
 wallbit[178]=8192
 wallbit[179]=64
 wallbit[182]=1
 wallbit[184]=8192
 wallbit[185]=64
 wallbit[188]=1
 wallbit[190]=8192
 wallbit[191]=64
 wallbit[194]=1
 wallbit[196]=8192
 wallbit[197]=64
 wallbit[200]=1
 wallbit[202]=8192
 wallbit[203]=64
 wallbit[206]=1
 wallbit[208]=8192
 wallbit[209]=64
 wallbit[212]=1
 wallbit[214]=8192
 wallbit[215]=64
 wallbit[218]=1
 wallbit[220]=12288
 wallbit[221]=64
 wallbit[224]=-1023
 wallbit[225]=-1
 wallbit[226]=8191
 wallbit[227]=64
 wallbit[230]=1537
 wallbit[233]=64
 wallbit[236]=513
 wallbit[239]=64
 wallbit[242]=513
 wallbit[245]=64
 wallbit[248]=513
 wallbit[251]=64
 wallbit[254]=513
 wallbit[257]=64
 wallbit[260]=513
 wallbit[263]=64
 wallbit[266]=513
 wallbit[269]=64
 wallbit[272]=513
 wallbit[275]=96
 wallbit[278]=513
 wallbit[279]=-4
 wallbit[280]=-1
 wallbit[281]=63
 wallbit[284]=513
 wallbit[285]=4
 wallbit[290]=513
 wallbit[291]=4
 wallbit[296]=513
 wallbit[297]=-4
 wallbit[298]=15
 wallbit[302]=513
 wallbit[304]=24
 wallbit[308]=513
 wallbit[310]=16
 wallbit[314]=513
 wallbit[316]=16
 wallbit[320]=513
 wallbit[322]=16
 wallbit[326]=513
 wallbit[328]=16
 wallbit[332]=513
 wallbit[334]=16
 wallbit[338]=513
 wallbit[340]=16
 wallbit[344]=513
 wallbit[346]=16
 wallbit[350]=-511
 wallbit[351]=2047
 wallbit[352]=16
 wallbit[356]=513
 wallbit[357]=3072
 wallbit[358]=16
 wallbit[362]=513
 wallbit[363]=2048
 wallbit[364]=16
 wallbit[368]=513
 wallbit[369]=2048
 wallbit[370]=16
 wallbit[374]=513
 wallbit[375]=2048
 wallbit[376]=16
 wallbit[380]=1537
 wallbit[381]=3072
 wallbit[382]=16
 wallbit[386]=-1023
 wallbit[387]=2047
 wallbit[388]=16
 wallbit[392]=1
 wallbit[394]=16
 wallbit[398]=1
 wallbit[400]=16
 wallbit[404]=1
 wallbit[406]=16
 wallbit[410]=1
 wallbit[412]=16
 wallbit[416]=1
 wallbit[418]=16
 wallbit[422]=1
 wallbit[424]=16
 wallbit[428]=1
 wallbit[430]=16
 wallbit[434]=3
 wallbit[436]=24
 wallbit[440]=-2
 wallbit[441]=-1
 wallbit[442]=15
 tmi[1]=1
 tmi[7]=2
 tmi[8]=3
 tmi[9]=4
 tmi[10]=5
 tmi[44]=6
 tmi[45]=7
 tmi[46]=8
 tmi[47]=9
 tmi[60]=10
 tmi[61]=11
 tmi[62]=12
 for i=1,5 do tcls[i]=1 end
 for i=6,12 do tcls[i]=2 end
 for i=1,8 do tmask[i]=255 end
 tmask[10]=1
 tmask[11]=3
 tmask[12]=7
 tmask[13]=15
 tmask[14]=31
 tmask[15]=63
 tmask[16]=127
 tmask[17]=254
 tmask[18]=252
 tmask[19]=248
 tmask[20]=240
 tmask[21]=224
 tmask[22]=192
 tmask[23]=128
 tmask[25]=127
 tmask[26]=63
 tmask[27]=31
 tmask[28]=15
 tmask[29]=7
 tmask[30]=3
 tmask[31]=1
 tmask[34]=128
 tmask[35]=192
 tmask[36]=224
 tmask[37]=240
 tmask[38]=248
 tmask[39]=252
 tmask[40]=254
 tmask[46]=1
 tmask[47]=3
 tmask[48]=6
 for i=49,56 do tmask[i]=36 end
 tmask[62]=128
 tmask[63]=192
 tmask[64]=96
 tmask[65]=36
 tmask[66]=36
 tmask[67]=4
 tmask[68]=4
 tmask[69]=228
 tmask[70]=228
 tmask[71]=36
 tmask[72]=36
 tmask[73]=12
 tmask[74]=24
 tmask[75]=48
 tmask[76]=96
 tmask[77]=192
 tmask[78]=128
 tmask[85]=255
 tmask[86]=255
 tmask[89]=48
 tmask[90]=24
 tmask[91]=12
 tmask[92]=6
 tmask[93]=3
 tmask[94]=1
 wpk[1]=1284
 wpk[2]=2571
 wpk[3]=2564
 wpk[4]=1291
 wpk[5]=1539
 wpk[6]=2571
 wpk[7]=2820
 wpk[8]=1290
end

function gd_4()
 wpk[9]=1795
 wpk[10]=2315
 wpk[11]=3077
 wpk[12]=1289
 wpk[13]=2051
 wpk[14]=2060
 wpk[15]=3078
 wpk[16]=1033
 wpk[17]=2307
 wpk[18]=2059
 wpk[19]=3335
 wpk[20]=1288
 wpk[21]=2564
 wpk[22]=1804
 wpk[23]=3336
 wpk[24]=1287
 wpk[25]=2820
 wpk[26]=1547
 wpk[27]=3337
 wpk[28]=1287
 wpk[29]=3077
 wpk[30]=1547
 wpk[31]=3338
 wpk[32]=1286
 wpk[33]=3077
 wpk[34]=1290
 wpk[35]=3082
 wpk[36]=1285
 wpk[37]=3334
 wpk[38]=1290
 wpk[39]=3083
 wpk[40]=1541
 wpk[41]=3335
 wpk[42]=1289
 wpk[43]=2828
 wpk[44]=1541
 wpk[45]=3336
 wpk[46]=1032
 wpk[47]=2572
 wpk[48]=1796
 wpk[49]=3337
 wpk[50]=1288
 wpk[51]=2317
 wpk[52]=2053
 wpk[53]=3082
 wpk[54]=1031
 wpk[55]=2061
 wpk[56]=2052
 wpk[57]=3083
 wpk[58]=1287
 wpk[59]=1805
 wpk[60]=2565
 wpk[61]=2828
 wpk[62]=1286
 wpk[63]=1549
 wpk[64]=2565
 wpk[65]=2828
 wpk[66]=1541
 wpk[67]=1548
 wpk[68]=2821
 wpk[69]=2573
 wpk[70]=1541
 wpk[71]=1292
 wpk[72]=2822
 wpk[73]=2317
 wpk[74]=1797
 wpk[75]=1035
 wpk[76]=2823
 wpk[77]=2061
 wpk[78]=2052
 wpk[79]=1034
 wpk[80]=3079
 wpk[81]=1805
 wpk[82]=2053
 wpk[83]=777
 wpk[84]=2824
 wpk[85]=1548
 wpk[86]=2308
 wpk[87]=776
 wpk[88]=3080
 wpk[89]=1292
 wpk[90]=2565
 wpk[91]=775
 wpk[92]=2825
 wpk[93]=1035
 wpk[94]=2565
 wpk[95]=774
 wpk[96]=2826
 wpk[97]=1035
 wpk[98]=2822
 wpk[99]=1030
 wpk[100]=2827
 wpk[101]=778
 wpk[102]=2822
 wpk[103]=1029
 wpk[104]=2571
 wpk[105]=777
 wpk[106]=2823
 wpk[107]=1284
 wpk[108]=2571
 wpk[109]=776
 wpk[110]=3080
 wpk[111]=1540
 wpk[112]=2316
 wpk[113]=775
 wpk[114]=2824
 wpk[115]=1795
 wpk[116]=2059
 wpk[117]=1030
 wpk[118]=3081
 wpk[119]=2051
 wpk[120]=2060
 wpk[121]=1029
 wpk[122]=2826
 wpk[123]=2307
 wpk[124]=1803
 wpk[125]=1284
 wpk[126]=2826
 wpk[127]=2563
 wpk[128]=1547
 bpk[1]=3850
 bpk[2]=3339
 bpk[3]=3343
 bpk[4]=3346
 bpk[5]=4116
 bpk[6]=4626
 bpk[7]=4622
 bpk[8]=4619
 bpk[9]=3850
 bpk[10]=3596
 bpk[11]=3343
 bpk[12]=3090
 bpk[13]=4116
 bpk[14]=4625
 bpk[15]=4622
 bpk[16]=4875
 bpk[17]=3849
 bpk[18]=3596
 bpk[19]=3344
 bpk[20]=3091
 bpk[21]=4116
 bpk[22]=4625
 bpk[23]=4877
 bpk[24]=4875
 bpk[25]=3851
 bpk[26]=3598
 bpk[27]=2833
 bpk[28]=3348
 bpk[29]=4115
 bpk[30]=4624
 bpk[31]=5133
 bpk[32]=4875
 bpk[33]=3852
 bpk[34]=3342
 bpk[35]=2834
 bpk[36]=3348
 bpk[37]=4370
 bpk[38]=5135
 bpk[39]=5133
 bpk[40]=4619
 bpk[41]=3853
 bpk[42]=3087
 bpk[43]=2834
 bpk[44]=3604
 bpk[45]=4369
 bpk[46]=5136
 bpk[47]=5133
 bpk[48]=4874
 bpk[49]=3853
 bpk[50]=3086
 bpk[51]=3090
 bpk[52]=3603
 bpk[53]=4625
 bpk[54]=5392
 bpk[55]=5133
 bpk[56]=4875
 bpk[57]=3853
 bpk[58]=3086
 bpk[59]=2833
 bpk[60]=3602
 bpk[61]=4625
 bpk[62]=5393
 bpk[63]=5390
 bpk[64]=4876
 bpk[65]=3853
 bpk[66]=3085
 bpk[67]=2833
 bpk[68]=3602
 bpk[69]=4626
 bpk[70]=5394
 bpk[71]=5390
 bpk[72]=4877
 bpk[73]=3853
 bpk[74]=2829
 bpk[75]=2832
 bpk[76]=3602
 bpk[77]=4627
 bpk[78]=5394
 bpk[79]=5391
 bpk[80]=4878
end

function gd_5()
 bpk[81]=3853
 bpk[82]=3084
 bpk[83]=2832
 bpk[84]=3602
 bpk[85]=4627
 bpk[86]=5139
 bpk[87]=5647
 bpk[88]=4878
 bpk[89]=3852
 bpk[90]=3085
 bpk[91]=2832
 bpk[92]=3601
 bpk[93]=4372
 bpk[94]=4884
 bpk[95]=5393
 bpk[96]=4879
 bpk[97]=3851
 bpk[98]=3340
 bpk[99]=3088
 bpk[100]=3602
 bpk[101]=4372
 bpk[102]=4884
 bpk[103]=5137
 bpk[104]=4623
 bpk[105]=3595
 bpk[106]=3085
 bpk[107]=3344
 bpk[108]=3859
 bpk[109]=4373
 bpk[110]=5139
 bpk[111]=5137
 bpk[112]=4366
 bpk[113]=3851
 bpk[114]=3084
 bpk[115]=3344
 bpk[116]=3603
 bpk[117]=4117
 bpk[118]=4884
 bpk[119]=4881
 bpk[120]=4622
 bpk[121]=3851
 bpk[122]=3085
 bpk[123]=3344
 bpk[124]=3603
 bpk[125]=4117
 bpk[126]=4884
 bpk[127]=4625
 bpk[128]=4622
 bpk[129]=3851
 bpk[130]=3341
 bpk[131]=3345
 bpk[132]=3348
 bpk[133]=4117
 bpk[134]=4628
 bpk[135]=4624
 bpk[136]=4621
 bpk[137]=3851
 bpk[138]=3342
 bpk[139]=3345
 bpk[140]=3092
 bpk[141]=4117
 bpk[142]=4371
 bpk[143]=4624
 bpk[144]=4622
 bpk[145]=3851
 bpk[146]=3342
 bpk[147]=3090
 bpk[148]=3092
 bpk[149]=4116
 bpk[150]=4371
 bpk[151]=4623
 bpk[152]=4876
 bpk[153]=3851
 bpk[154]=3598
 bpk[155]=2833
 bpk[156]=2835
 bpk[157]=3605
 bpk[158]=4116
 bpk[159]=4624
 bpk[160]=4877
 bpk[161]=3852
 bpk[162]=3342
 bpk[163]=2833
 bpk[164]=2835
 bpk[165]=3604
 bpk[166]=4115
 bpk[167]=5135
 bpk[168]=4877
 bpk[169]=3853
 bpk[170]=3087
 bpk[171]=2577
 bpk[172]=3092
 bpk[173]=3604
 bpk[174]=4369
 bpk[175]=4880
 bpk[176]=4877
 bpk[177]=3853
 bpk[178]=3086
 bpk[179]=2576
 bpk[180]=2835
 bpk[181]=3603
 bpk[182]=4370
 bpk[183]=5135
 bpk[184]=4876
 bpk[185]=3853
 bpk[186]=3086
 bpk[187]=2575
 bpk[188]=2578
 bpk[189]=3347
 bpk[190]=4370
 bpk[191]=5136
 bpk[192]=5133
 bpk[193]=3853
 bpk[194]=3085
 bpk[195]=2575
 bpk[196]=2578
 bpk[197]=3602
 bpk[198]=4370
 bpk[199]=5136
 bpk[200]=4877
 bpk[201]=3853
 bpk[202]=3084
 bpk[203]=2574
 bpk[204]=2577
 bpk[205]=3602
 bpk[206]=4370
 bpk[207]=5137
 bpk[208]=4878
 bpk[209]=3853
 bpk[210]=3083
 bpk[211]=2574
 bpk[212]=2576
 bpk[213]=3602
 bpk[214]=4371
 bpk[215]=5137
 bpk[216]=4878
 bpk[217]=3852
 bpk[218]=3082
 bpk[219]=2829
 bpk[220]=3088
 bpk[221]=3601
 bpk[222]=4372
 bpk[223]=5138
 bpk[224]=4879
 bpk[225]=3851
 bpk[226]=3338
 bpk[227]=2829
 bpk[228]=2831
 bpk[229]=3602
 bpk[230]=4115
 bpk[231]=5138
 bpk[232]=4623
 bpk[233]=3850
 bpk[234]=3083
 bpk[235]=2829
 bpk[236]=3344
 bpk[237]=3859
 bpk[238]=4628
 bpk[239]=5137
 bpk[240]=4366
 bpk[241]=3850
 bpk[242]=3083
 bpk[243]=3086
 bpk[244]=3345
 bpk[245]=4116
 bpk[246]=4883
 bpk[247]=4623
 bpk[248]=4364
 bpk[249]=3850
 bpk[250]=3083
 bpk[251]=3342
 bpk[252]=3345
 bpk[253]=4116
 bpk[254]=4882
 bpk[255]=4623
 bpk[256]=4364
 cpx[1]=300
 cpx[2]=486
 cpx[3]=342
 cpy[1]=229
 cpy[2]=294
 cpy[3]=510
 cpdx[2]=1
 cpdx[3]=1
 cpdy[1]=1
 cpdy[2]=1
 cpdy[3]=1
 cpl[1]=71
 cpl[2]=72
 cpl[3]=72
end

function gd_init()
 gd_1()
 gd_2()
 gd_3()
 gd_4()
 gd_5()
 for i = 0, 95 do
  div3[i + 1] = i \ 3
  div3x30[i + 1] = (i \ 3) * 30
 end
 for i = 0, 29 do
  cs_lut[i + 1] = (i * 10) \ 3
 end
 for i = 1, 31 do
  ckdl[i + 1] = ckd(i)
  ckdl2[i + 1] = ckd(i + decb)
 end
end
-- ==== GENERATED DATA END ====

-- driftmania — gametank port (playable slice: track a1)
-- Adapted from "Driftmania" by Max Bize (maxbize / Frenchie14)
-- https://github.com/maxbize/PICO-8 — licensed CC-BY-NC-SA 4.0.
-- This hand-port to gtlua (real physics, real track data, real car art)
-- is released under the same license: CC-BY-NC-SA 4.0. See LICENSE.
-- See PORT_NOTES.md for every divergence from the original cart.
--
-- controls: ⬆️/🅾️ (GT A) accelerate, ⬇️ brake/reverse, ⬅️➡️ steer,
--           ❎ (GT B) drift handbrake, START restart race
--
-- build: node ports/driftmania/build.mjs   (2 MB FLASH2M banked cart;
--   the flat 32 KB CLI build overflows RAM+flash — see PORT_NOTES.md)
--
-- The original runs its physics in _update60; this port runs _update()
-- (30 fps) with the cart's constants rescaled: per-frame velocity deltas
-- x4 (two 60fps steps at doubled px/frame units), velocities x2, turn
-- rates x2, the 0.94 over-limit decay becomes 0.94^2 = 0.88.

-- car state (positions are whole pixels + 16.16 remainders, like the cart)
local carx = 0
local cary = 0
local vx = 0.0
local vy = 0.0
local xrem = 0.0
local yrem = 0.0
local angf = 0.0          -- facing angle in turns
local ai = 0              -- facing snapped to 1/32s: frame + table index
local spd = 0.0
local drift = 0            -- 0/1 (gtlua stores no booleans)
local wallpen = 0         -- wall-hit penalty frames
local wallnear = 0        -- prop chunks near car this frame (cheap gate)
local cpnear = 0          -- checkpoint lines near car this frame
local gwheels = 0         -- wheels on grass this frame
local kph = 0

-- race state
local state = 0           -- 0 countdown, 1 racing, 2 finished
local anim = 0
local lap = 1
local frame = 0
local lapstart = 0
local lastlap = 0
local finfr = 0
local lappop = 0
local nextcp = 2
local cpc = array(8)      -- checkpoint-crossed flags

-- lap time store
local laptf = array(8)

-- hud timer (incremental: avoids divides every frame)
local tmm = 0
local tms = 0
local tcs = 0.0

-- camera (fixed-point target, int applied)
-- camera as int world position + fractional remainder: the smooth-follow
-- accumulator spans the whole 656px world, which overflows the 8.8 number
-- range under --num8. The chase delta is always small, so only the
-- fraction needs to be a number; flr(camx) == camxw by construction.
local camxw = 0
local camyw = 0
local camxf = 0.0
local camyf = 0.0
local camxi = 0
local camyi = 0

-- drift/dirt trail ring buffer (world-space pset marks)
local tlx = array(64)
local tly = array(64)
local tlc = array(64)
local tri = 1
local tstep = 0

-- props collected during the map pass, drawn above the car
local plx = array(49)
local ply = array(49)
local plk = array(49)
local pcount = 0

-- audio latches
local engp = 0.0
local englast = -1
local sklast = 0
local grlast = 0
local beept = 0

function sgn0(v)
  if (v > 0) return 1
  if (v < 0) return -1
  return 0
end

-- ---- packed-data unpackers -------------------------------------------------
-- The generated tables pack two small values per gtlua int to fit the
-- GameTank's ~7 KB RAM (see PORT_NOTES.md). All unpackers are pure and cheap.
--   ckdt[i] = draw-kind (low byte) | uniform-tile (high byte)
--   ctiles  = flat tile-def ids, two per int (low = even flat index)
--   wpk     = per-angle/wheel offset, (x+8) | (y+8)<<8
--   bpk     = per-angle bbox probe,  (dx+16) | (dy+16)<<8

function ckd(i)
  return ckdt[i] & 255
end

function ckt(i)
  return ckdt[i] >> 8
end

-- flat 0-based tile-def index -> tile id (0-127)
function ctile(idx)
  local w = ctiles[(idx >> 1) + 1]
  if (idx & 1) == 0 then
    return w & 255
  end
  return w >> 8
end

-- tile-coord mod 3 (no runtime divide; div3 is precomputed)
function m3(tc)
  return tc - div3[tc + 1] * 3
end

-- ---- map lookups ----------------------------------------------------------

function road_tile(tx, ty)
  local cg = cgrid[div3x30[ty + 1] + div3[tx + 1] + 1]
  local r = cg & 31
  if (r == 0) return 0
  local k = ckd(r)
  if (k < 16) return ckt(r)
  return ctile((k - 16) * 9 + m3(ty) * 3 + m3(tx))
end

function prop_tile(tx, ty)
  local cg = cgrid[div3x30[ty + 1] + div3[tx + 1] + 1]
  local p = cg >> 10
  if (p == 0) return 0
  local k = ckd(p + propb)
  if (k < 16) return ckt(p + propb)
  return ctile((k - 16) * 9 + m3(ty) * 3 + m3(tx))
end

function grass_at(px, py)
  if (px < 0 or px > 719 or py < 0 or py > 719) return 0
  local t = road_tile(px >> 3, py >> 3)
  local mi = tmi[t + 1]
  if (mi == 0) return 0
  if (tcls[mi] != 1) return 0
  return (tmask[(mi - 1) * 8 + (py & 7) + 1] >> (px & 7)) & 1
end

function wallmask(px, py, tx, ty)
  local t = prop_tile(tx, ty)
  local mi = tmi[t + 1]
  if (mi == 0) return 0
  if (tcls[mi] != 2) return 0
  return (tmask[(mi - 1) * 8 + (py & 7) + 1] >> (px & 7)) & 1
end

-- car-vs-wall: 8 outline points for the current facing (bbx/bby), a
-- bit-grid pretest per tile, pixel mask only when the tile has wall ink
function collides_at(x, y)
  local b = ai * 8
  for j = 1, 8 do
    local w = bpk[b + j]
    local px = x + (w & 255) - 16
    local py = y + (w >> 8) - 16
    if (px < 2 or px > 717 or py < 2 or py > 717) return 1
    local tx = px >> 3
    local ty = py >> 3
    if ((wallbit[ty * 6 + (tx >> 4) + 1] >> (tx & 15)) & 1) != 0 then
      if (wallmask(px, py, tx, ty) != 0) return 1
    end
  end
  return 0
end

-- ---- checkpoints / laps -----------------------------------------------------

function on_cp(c)
  if c == 1 then
    if (nextcp != 1) return
    lastlap = frame - lapstart
    lapstart = frame
    laptf[lap] = lastlap
    lappop = 45
    for i = 1, ncp do cpc[i] = 0 end
    nextcp = 2
    if lap == nlaps then
      state = 2
      finfr = frame
      gt.note(3, 88, 70)
      beept = 12
    else
      lap += 1
      gt.note(3, 83, 60)
      beept = 6
    end
    return
  end
  if (cpc[c] != 0) return
  cpc[c] = 1
  nextcp = (nextcp % ncp) + 1
  gt.note(3, 76, 50)
  beept = 4
end

-- ---- movement ---------------------------------------------------------------

function add_trail(x, y, c)
  tlx[tri] = x
  tly[tri] = y
  tlc[tri] = c
  tri += 1
  if (tri > 64) tri = 1
end

-- per-pixel-step events: checkpoint lines (all 4 wheels, exact-pixel
-- crossings like the cart) + drift trail from alternating rear wheels
function wheelx(wb, j)
  return (wpk[wb + j + 1] & 255) - 8
end

function wheely(wb, j)
  return (wpk[wb + j + 1] >> 8) - 8
end

function step_events()
  if cpnear == 0 then
    if drift != 0 then
      tstep = 1 - tstep
      local wb2 = ai * 4
      local wj = tstep * 2
      add_trail(carx + wheelx(wb2, wj), cary + wheely(wb2, wj), 0)
    end
    return
  end
  local wb = ai * 4
  for j = 0, 3 do
    local wx = carx + wheelx(wb, j)
    local wy = cary + wheely(wb, j)
    for c = 1, ncp do
      local d1 = wx - cpx[c]
      local d2 = wy - cpy[c]
      if cpdx[c] == 0 then
        if (d1 == 0 and d2 >= 0 and d2 < cpl[c]) on_cp(c)
      elseif cpdy[c] == 0 then
        if (d2 == 0 and d1 >= 0 and d1 < cpl[c]) on_cp(c)
      else
        if (d1 == d2 and d1 >= 0 and d1 < cpl[c]) on_cp(c)
      end
    end
  end
  if drift != 0 then
    tstep = 1 - tstep
    -- alternate the two rear wheels (offset-table wheels 0 and 2)
    local wj = tstep * 2
    add_trail(carx + wheelx(wb, wj), cary + wheely(wb, wj), 0)
  end
end

function move_x()
  xrem += vx
  local mv = flr(xrem + 0.5)
  xrem -= mv
  if (mv == 0) return 0
  local sg = 1
  if (mv < 0) sg = -1
  while mv != 0 do
    if wallnear != 0 and collides_at(carx + sg, cary) != 0 then
      return 1
    end
    carx += sg
    mv -= sg
    step_events()
  end
  return 0
end

function move_y()
  yrem += vy
  local mv = flr(yrem + 0.5)
  yrem -= mv
  if (mv == 0) return 0
  local sg = 1
  if (mv < 0) sg = -1
  while mv != 0 do
    if wallnear != 0 and collides_at(carx, cary + sg) != 0 then
      return 1
    end
    cary += sg
    mv -= sg
    step_events()
  end
  return 0
end

-- ---- race lifecycle ---------------------------------------------------------

function reset()
  carx = spawnx
  cary = spawny
  angf = spawndir
  ai = flr(angf * 32 + 0.5) % 32
  vx = 0
  vy = 0
  xrem = 0
  yrem = 0
  spd = 0
  drift = 0
  wallpen = 0
  state = 0
  anim = 0
  lap = 1
  frame = 0
  ckf = 0
  cks = 0
  ckm = 0
  lapstart = 0
  lastlap = 0
  finfr = 0
  lappop = 0
  nextcp = 2
  for i = 1, 8 do cpc[i] = 0 end
  for i = 1, 8 do laptf[i] = 0 end
  tmm = 0
  tms = 0
  tcs = 0
  camxw = spawnx - 64
  camyw = spawny - 64
  camxf = 0
  camyf = 0
  camxi = mid(0, spawnx - 64, 592)
  camyi = mid(0, spawny - 64, 592)
  for i = 1, 64 do tlc[i] = -1 end
  tri = 1
  tstep = 0
  engp = 0
  englast = -1
  sklast = 0
  grlast = 0
  beept = 0
  gt.noteoff(0)
  gt.noteoff(1)
  gt.noteoff(2)
  gt.noteoff(3)
end

function _init()
  gt.autocls(3)                 -- frame clear rides the post-flip vsync wait
  gd_init()
  atlas_init()
  reset()
end

-- ---- update -----------------------------------------------------------------

function _update()
  if (btnp(7)) reset()

  if state == 0 then
    anim += 1
    if anim == 1 or anim == 23 or anim == 45 then
      gt.note(3, 64, 60)
      beept = 5
    end
    if anim == 67 then
      gt.note(3, 88, 70)
      beept = 10
      state = 1
    end
  elseif state == 1 then
    if (anim < 120) anim += 1
    frame += 1
    ckf += 1
    if ckf >= 30 then
     ckf = 0
     cks += 1
     if cks >= 60 then
      cks = 0
      ckm += 1
     end
    end
    tcs += 3.3333
    if tcs >= 100 then
      tcs -= 100
      tms += 1
      if tms == 60 then
        tms = 0
        tmm += 1
      end
    end
  end
  if (lappop > 0) lappop -= 1
  if beept > 0 then
    beept -= 1
    if (beept == 0) gt.noteoff(3)
  end

  -- input (live only while racing; the cart also runs the car with no
  -- input during the countdown and the results screen)
  local mside = 0
  local mfwd = 0
  local dbrake = 0
  if state == 1 then
    if (btn(0)) mside += 1
    if (btn(1)) mside -= 1
    if (btn(4) or btn(2)) mfwd += 1
    if (btn(3)) mfwd -= 1
    if (btn(5)) dbrake = 1
  elseif state == 2 then
    if (btnp(4)) reset()
  end

  -- ---- _car_move (cart physics, 30fps-rescaled constants) ----
  local fwdx = cos(angf)
  local fwdy = sin(angf)
  spd = sqrt(vx * vx + vy * vy)
  local nx = 0
  local ny = 0
  -- unit velocity. Fast path (spd >= 0.5): ONE reciprocal + two multiplies
  -- instead of two full divides — but ONLY here, because 1/spd for small spd
  -- exceeds the 8.8 num8 range (1/0.5 = 2 is safe; 1/0.01 = 100 wraps) and
  -- would corrupt nx/ny. Near standstill, fall back to the direct divides
  -- (their result is always <= 1 so they never overflow); it's cold and the
  -- normalization barely matters at crawling speed.
  if spd >= 0.5 then
    local invspd = 1 / spd
    nx = vx * invspd
    ny = vy * invspd
  elseif spd > 0 then
    nx = vx / spd
    ny = vy / spd
  end
  local vdotf = fwdx * nx + fwdy * ny

  -- wheel surface modifiers
  gwheels = 0
  local wb = ai * 4
  for j = 0, 3 do
    if (grass_at(carx + wheelx(wb, j), cary + wheely(wb, j)) != 0) gwheels += 1
  end
  local modturn = 1
  local modcorr = 1
  local modaccel = 1
  local modbrake = 1
  local modmax = 1
  if gwheels >= 2 then
    modturn = 0.25
    modcorr = 0.25
    modaccel = 0.5
    modbrake = 0.25
  end
  if wallpen > 0 then
    wallpen -= 1
    modmax = 0.8
    modaccel = 0.2
  end

  -- reduced steering when slow (and no handbrake)
  if spd < 1 then
    mside *= spd
    dbrake = 0
  end

  -- facing rotation; snap to 1/32s when no steer input
  local tmul = 1
  if (dbrake != 0) tmul = 1.35
  angf = (angf + mside * 0.012 * tmul) % 1
  if mside == 0 then
    angf = (flr(angf * 32 + 0.5) / 32) % 1
  end
  ai = flr(angf * 32 + 0.5) % 32

  -- checkpoint proximity gate: the per-pixel step scan only runs when
  -- the car's box could touch a line this frame (bounds are conservative:
  -- car 8px + wheels 6 + max speed 5)
  cpnear = 0
  for c = 1, ncp do
    if cpdx[c] == 0 then
      if carx + 20 >= cpx[c] and carx - 20 <= cpx[c] and
         cary + 20 >= cpy[c] and cary - 20 <= cpy[c] + cpl[c] then cpnear = 1 end
    elseif cpdy[c] == 0 then
      if cary + 20 >= cpy[c] and cary - 20 <= cpy[c] and
         carx + 20 >= cpx[c] and carx - 20 <= cpx[c] + cpl[c] then cpnear = 1 end
    else
      if carx + 20 >= cpx[c] and carx - 20 <= cpx[c] + cpl[c] and
         cary + 20 >= cpy[c] and cary - 20 <= cpy[c] + cpl[c] then cpnear = 1 end
    end
  end

  -- wall proximity gate: prop chunks within reach this frame?
  wallnear = 0
  local txa = (carx - 14) >> 3
  local txb = (carx + 14) >> 3
  local tya = (cary - 14) >> 3
  local tyb = (cary + 14) >> 3
  if ((cgrid[div3x30[tya + 1] + div3[txa + 1] + 1] >> 10) != 0) wallnear = 1
  if ((cgrid[div3x30[tya + 1] + div3[txb + 1] + 1] >> 10) != 0) wallnear = 1
  if ((cgrid[div3x30[tyb + 1] + div3[txa + 1] + 1] >> 10) != 0) wallnear = 1
  if ((cgrid[div3x30[tyb + 1] + div3[txb + 1] + 1] >> 10) != 0) wallnear = 1

  -- unstick nudge (the cart pushes away from the colliding point)
  if wallnear != 0 then
    local tries = 0
    while tries < 3 and collides_at(carx, cary) != 0 do
      local dxp = sgn0(-vx)
      local dyp = sgn0(-vy)
      if dxp == 0 and dyp == 0 then
        dxp = sgn0(-fwdx)
        dyp = sgn0(-fwdy)
      end
      carx += dxp
      cary += dyp
      tries += 1
    end
  end

  -- acceleration / friction / braking
  if dbrake != 0 then
    local fstop = 0.2 * modbrake
    if mfwd > 0 then
      fstop = 0.02
    elseif mfwd == 0 then
      fstop = 0.12
    end
    vx -= mid(nx * fstop, vx, -vx)
    vy -= mid(ny * fstop, vy, -vy)
  else
    if mfwd > 0 then
      vx += fwdx * 0.3 * modaccel
      vy += fwdy * 0.3 * modaccel
    elseif mfwd < 0 then
      vx -= fwdx * 0.2 * modbrake
      vy -= fwdy * 0.2 * modbrake
    else
      vx -= mid(nx * 0.08, vx, -vx)
      vy -= mid(ny * 0.08, vy, -vy)
    end
  end

  -- corrective side force (kills lateral slide unless drifting)
  local rxx = fwdy
  local ryy = -fwdx
  local vdotr = rxx * nx + ryy * ny
  drift = dbrake
  if dbrake == 0 then
    local cf = (1 - abs(vdotf)) * 0.4 * modcorr * sgn(vdotr)
    vx -= mid(cf * rxx, vx, -vx)
    vy -= mid(cf * ryy, vy, -vy)
  end

  -- speed limit, direct vector scaling (the angle round-trip — atan2 +
  -- two cos/sin reconstructions — becomes one conditional divide). Gate on
  -- the SQUARED magnitude: the always-on path needs NO sqrt (this spd is
  -- never read before the recompute below), so only the capping frames pay
  -- a sqrt + divide.
  local lim = 4.4 * modmax
  if (vdotf < -0.8) lim = 1.0 * modmax
  if vx * vx + vy * vy > lim * lim then
    spd = sqrt(vx * vx + vy * vy)
    local ns = max(spd * 0.88, lim)
    local k = ns / spd
    vx *= k
    vy *= k
  end

  -- velocity rotates toward the facing (the drift feel): rotate the
  -- vector directly; the turn direction is the cross-product sign
  -- (fwd x v), replacing the angle-difference test
  local vrot = 0.010 * abs(vdotr) * modturn
  if (fwdx * vy - fwdy * vx < 0) vrot = -vrot
  local sr = sin(vrot)
  local cr = cos(vrot)
  local nvx = vx * cr - vy * sr
  vy = vx * sr + vy * cr
  vx = nvx

  -- pixel-stepped movement with wall blocking
  local xb = move_x()
  local yb = move_y()
  if xb != 0 then
    vx *= 0.25
    vy *= 0.90
  end
  if yb != 0 then
    vx *= 0.90
    vy *= 0.25
  end
  if xb != 0 or yb != 0 then
    wallpen = 10
    gt.note(3, 32, 70)
    beept = 3
  end

  spd = sqrt(vx * vx + vy * vy)
  local s8 = flr(spd * 8)
  kph = s8 * 4 + s8 \ 32

  -- dirt kicked up by a front wheel on grass (once per frame)
  if gwheels > 0 and spd > 1 then
    add_trail(carx + wheelx(wb, 1), cary + wheely(wb, 1), 4)
  end

  -- camera: lead toward travel direction, hard-clamped to the world
  local lead = min(spd * 4.95, 30)
  local ctx = carx - 64 + flr(fwdx * lead)
  local cty = cary - 64 + flr(fwdy * lead)
  camxf += ((ctx - camxw) - camxf) * 0.75
  camyf += ((cty - camyw) - camyf) * 0.75
  local cw = flr(camxf)
  camxw += cw
  camxf -= cw
  cw = flr(camyf)
  camyw += cw
  camyf -= cw
  camxi = mid(0, camxw, 592)
  camyi = mid(0, camyw, 592)

  -- ---- audio (gt.note approximations of the cart's sfx) ----
  local tp = spd * 4
  if mfwd < 0 then
    tp = spd * 2
  elseif dbrake != 0 or mfwd == 0 then
    tp = spd * 3
  end
  if (state == 2) tp = 0
  if engp != tp then
    engp += sgn(tp - engp) * 0.5
    if (engp < 0) engp = 0
  end
  local en = 24 + flr(engp)
  if en != englast then
    englast = en
    gt.note(0, en, 30)
  end

  if drift != 0 and spd > 1.6 then
    local sk = 52
    if ((frame & 4) != 0) sk = 49
    if sk != sklast then
      sklast = sk
      gt.note(1, sk, 22)
    end
  else
    if (sklast != 0) gt.noteoff(1)
    sklast = 0
  end

  if gwheels >= 2 and spd > 1 then
    if (grlast == 0) gt.note(2, 14, 30)
    grlast = 1
  else
    if (grlast != 0) gt.noteoff(2)
    grlast = 0
  end
end

-- ---- draw -------------------------------------------------------------------

-- PERF: chunk kinds are pre-rendered into a GRAM atlas at init (atlas_init);
-- each 3x3-tile chunk draws as ONE gt.gspr blit, INLINED at the three call
-- sites — the cc65 call overhead for the old draw_tiles() wrapper measured
-- ~1,200 cycles per invocation x ~23 chunks/frame = 0.47 vsyncs of pure
-- calling convention. See docs/performance.md.

function atlas_init()
  gt.bg_clear()
  local a = 0
  while a <= 52 do
    local bidx = a * 9
    local bx = (a & 7) * 24
    local by = (a >> 3) * 24
    for ty2 = 0, 2 do
      for tx2 = 0, 2 do
        local t = ctile(bidx)
        bidx += 1
        if (t != 0) gt.bg_tile(t, bx + tx2 * 8, by + ty2 * 8)
      end
    end
    a += 1
  end
end

function pad2(v, x, y, c)
  if (v < 10) x = print(0, x, y, c)
  return print(v, x, y, c)
end

function fmt_clock(x, y, c)
  x = print(ckm, x, y, c)
  x = print(":", x, y, c)
  x = pad2(cks, x, y, c)
  x = print(".", x, y, c)
  x = pad2(cs_lut[ckf + 1], x, y, c)
  return x
end

function fmt_time(fr, x, y, c)
  local s = fr \ 30
  local cs2 = (fr % 30) * 10 \ 3
  local m = s \ 60
  s = s % 60
  x = print(m, x, y, c)
  x = print(":", x, y, c)
  x = pad2(s, x, y, c)
  x = print(".", x, y, c)
  x = pad2(cs2, x, y, c)
  return x
end

function lights(x, y)
  local c = 1
  if anim > 67 then
    c = 11
  elseif anim > 45 then
    c = 9
  elseif anim > 22 then
    c = 8
  end
  rectfill(x - 1, y - 1, x + 47, y + 19, c)
  rectfill(x, y, x + 46, y + 18, 0)
  for i = 0, 2 do
    local col = 1
    if (anim > 22 * (i + 1)) col = c
    circfill(x + 9 + 14 * i, y + 9, 5, col)
    circ(x + 9 + 14 * i, y + 9, 5, 6)
  end
end

function hud()
  local hx = camxi
  local hy = camyi
  fmt_clock(hx + 2, hy + 2, 7)
  local rx = print("lap ", hx + 96, hy + 2, 7)
  rx = print(lap, rx, hy + 2, 7)
  rx = print("/", rx, hy + 2, 7)
  print(nlaps, rx, hy + 2, 7)
  rx = print(kph, hx + 100, hy + 121, 7)
  print(" kph", rx, hy + 121, 7)

  if (anim <= 90 and state != 2) lights(hx + 40, hy + 24)

  if (lappop > 0 and state == 1) fmt_time(lastlap, hx + 46, hy + 34, 7)

  if state == 2 then
    rectfill(hx + 10, hy + 28, hx + 117, hy + 88, 1)
    rect(hx + 9, hy + 27, hx + 118, hy + 89, 12)
    print("race complete", hx + 38, hy + 32, 7)
    local rx2 = print("time ", hx + 24, hy + 44, 7)
    fmt_time(finfr, rx2, hy + 44, 7)
    local bl = laptf[1]
    for i = 2, nlaps do
      if (laptf[i] < bl) bl = laptf[i]
    end
    rx2 = print("best lap ", hx + 24, hy + 52, 6)
    fmt_time(bl, rx2, hy + 52, 6)
    if finfr <= mplat then
      print("platinum medal", hx + 36, hy + 64, 7)
    elseif finfr <= mgold then
      print("gold medal", hx + 44, hy + 64, 10)
    elseif finfr <= msilver then
      print("silver medal", hx + 40, hy + 64, 6)
    elseif finfr <= mbronze then
      print("bronze medal", hx + 40, hy + 64, 9)
    else
      print("no medal", hx + 48, hy + 64, 5)
    end
    print("press a to retry", hx + 32, hy + 78, 7)
  end
end

function _draw()
  camera(camxi, camyi)

  -- visible chunk window (24px chunks; div3 tables avoid runtime divides)
  local cx0 = div3[(camxi >> 3) + 1]
  local cx1 = div3[((camxi + 127) >> 3) + 1]
  local cy0 = div3[(camyi >> 3) + 1]
  local cy1 = div3[((camyi + 127) >> 3) + 1]
  -- the whole window renders in asm (gt_chunks.s): road + decal layers,
  -- flat-run merging, atlas blits; props come back as a byte list
  gt.chunks_draw(cgrid, ckdl, ckdl2, cprops, 30, cx0, cy0, cx1, cy1)
  pcount = 0
  local pk = 1
  while cprops[pk] > 0 do
    pcount += 1
    plk[pcount] = ckd(cprops[pk] + propb)
    plx[pcount] = cprops[pk + 1] + camxi   -- engine emits screen x; back to world
    ply[pcount] = cprops[pk + 2] + camyi
    pk += 3
  end

  -- tire trails
  for i = 1, 64 do
    if (tlc[i] >= 0) pset(tlx[i], tly[i], tlc[i])
  end

  -- next-checkpoint hint (blinking line; the cart pal-flashes the decal)
  if state == 1 and (frame & 8) == 0 then
    local c = nextcp
    line(cpx[c], cpy[c], cpx[c] + cpdx[c] * (cpl[c] - 1),
         cpy[c] + cpdy[c] * (cpl[c] - 1), 7)
  end

  -- the car (pre-rotated 16x16 frames baked into sheet cells 128-255;
  -- cell = 128 + (ai>>3)*32 + (ai&7)*2, per gen.js's carCell layout)
  spr(128 + (ai >> 3) * 32 + (ai & 7) * 2, carx - 8, cary - 10, 2, 2)

  -- props above the car (trees, fences)
  for i = 1, pcount do
    local k = plk[i]
    if k >= 16 then
      gt.gspr(((k - 16) & 7) * 24, ((k - 16) >> 3) * 24, 24, 24, plx[i], ply[i])
    else
      rectfill(plx[i], ply[i], plx[i] + 23, ply[i] + 23, k)
    end
  end

  hud()
end
