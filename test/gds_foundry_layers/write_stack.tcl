# Paint one rectangle on every routing metal and stream the cell out, so the
# written GDS carries exactly the routing layers under test.
#   TECHF : techfile (foundry-mapped or compact)   OUT : streamout target
drc off
tech load ./$env(TECHF)
load geo -quiet
box 0 0 1000 200
paint met1
box 0 300 1000 500
paint met2
box 0 600 1000 800
paint met3
save geo
load geo
gds write $env(OUT)
quit -noprompt
