// ColorPicker 1.0 (2018/01/28) by Typhaine Artez
//
// Provided under Creative Commons Attribution-Non-Commercial-ShareAlike 4.0 International license.
// Please be sure you read and adhere to the terms of this license: https://creativecommons.org/licenses/by-nc-sa/4.0/
//
//  Made with love, wanting the optimal color picker, one mesh object, optimized script, self contained.
//  Thanks to Cheetos Brat for the face params work on the mesh object
//  Slider texture offset idea borrowed Chimera Firecaster (and by her Nova Convair)
//  HSV/RGB conversion functions adapted from Sally LaSalle (http://wiki.secondlife.com/wiki/Color_conversion_scripts)
//
// Usage:
//  1) link the picker to your build (hud)
//  2) communicate with it through link messages
//  3) that's all :)
//
// The picker accepts in input only setting some options that you can group in one message if you want
// (separate options with a ~):
//  llMessageLinked(link_number_of_picker, 0, options, (key)"ColorPicker");
// options can be:
//  rgb=<RGB vector>
//      send a new (or initial) color by its RGB (LSL) vector
//  hsv=<HSV vector>
//      send a new (or initial) color by its HSV (Hue/Saturation/Value) vector
//  sliderColor=<RGB vector> (white by default - <1, 1, 1>)
//      set a color for the hue slider at the bottom
//  public=1 or 0 (0 by default)
//      allow anyone to manipulate the picker when rezzed on a region
//  selectOnly=1 or 0 (0 by default)
//      send a message only when a color is selected (not while dragging)
//  sendHSV=1 or 0 (0 by default)
//      ask the color sent by the picker is inthe HSV format (RGB by default)
//  sendTo=linkNumber or -1 (-1 by default - all links)
//      ask the picker to send messages to a specific link, or all links in the linkset
//
// i.e.
//  llMessageLinked(pickerLink, 0, "rgb=<1,1,1>", (key)"ColorPicker");
// or
//  llMessageLinked(pickerLink, 0, "rgb=<1,1,1>~sendHSV=1~public=1~selectOnly=1", (key)"ColorPicker");
//
// The picker will send messages to the asked link (sendTo option) or all links.
// The key part will always be "ColorPicker" (as asked in input)
// The number tells the reason of the message:
//  -1  user is dragging the cursors and selectOnly=FALSE
//  1   user selected a color (end of drag or just touched)
//  2   user clicked the color preview part
//
// To request a color from the picker, send a message with 3 in the number. It will reply the color
// (in the format specified in options, RGB by default) with a message with the number -3.

//integer PART_GRADIENT = 1;
//integer PART_HUEBAR = 2;
integer PART_PREVIEW = 4;
integer PART_CURHUE = 0;        // modified with hue (max saturation/max value)
integer PART_PICKER = 3;        // circle picker (texture offset)
integer PART_SLIDER = 5;        // hue bar slider (texture offset)

float UPDATE_PER_SECOND = 50;   // number of time color will be outputed per second

key toucher = NULL_KEY;         // keep trap of the 'dragging' status
integer touchedPart = 0;        // which part the user touched

vector HSV = <0.5, 0.5, 0.5>;       // initial HSV color (much easier to deal with than HSL)
vector coordPre = <1.0, 1.0, 0.0>;  // last coordinates position (x=saturation, y=value)

// user options (set by link message during init)
integer ownerOnly = TRUE;   // only user can touch and use
integer selectOnly = FALSE; // send the color only when the user releases the cursors
integer sendHSV = FALSE;    // send resulting color in HSV instead of RGB
integer sendTo = LINK_ALL_OTHERS;   // send to?

DBG(string msg) {
    llOwnerSay(msg);
}

vector hsv2rgb(vector hsv) {
    // hue
    float h = hsv.x;
    if (h < 0.0) h = 0.0;
    else if (h >= 1.0) h = 6.0;
    else h *= 6.0; // range 0 to 5 (for the 6 division of the chromatic circle)

    //saturation
    float s = hsv.y;
    if (s < 0.0) s = 0.0;
    else if (s > 1.0) s = 1.0;

    // value
    float v = hsv.z;
    if (v < 0.0) v = 0.0;
    else if (v > 1.0) v = 1.0;

    // achromatic (grey)
    if (s == 0.0) return <v, v, v>;

    integer i = llFloor(h);
    float f = h - i;   // factorial part of hue
    float p = v * (1.0 - s);
    float q = v * (1.0 - s * f);
    float t = v * (1.0 - s * (1.0 -f));

    if (i == 0) return <v, t, p>;
    if (i == 1) return <q, v, p>;
    if (i == 2) return <p, v, t>;
    if (i == 3) return <p, q, v>;
    if (i == 4) return <t, p, v>;
    /* i == 5 */return <v, p, q>;
}

vector rgb2hsv(vector rgb) {
    // red
    float r = rgb.x;
    if (r < 0.0) r = 0.0;
    else if (r > 1.0) r = 1.0;

    // green
    float g = rgb.y;
    if (g < 0.0) g = 0.0;
    else if (g > 1.0) g = 1.0;

    // blue
    float b = rgb.z;
    if (b < 0.0) b = 0.0;
    else if (b > 1.0) b = 1.0;

    float min = llListStatistics(LIST_STAT_MIN, [r,g,b]);
    float max = llListStatistics(LIST_STAT_MAX, [r,g,b]);

    float h; float s;
    float v = max;
    if (max == 0.0) return ZERO_VECTOR; // value=0=black

    float d = max - min; // delta
    s = d / max;

    if (r == g && g == b) h = 0; // achromatic
    else if (r == max) h = 0 + (g - b) / d; // between red and yellow
    else if (g == max) h = 2 + (b - r) / d; // between yellowand cyan
    else               h = 4 + (r - g) / d; // between cyan & red

    h /= 6.0;   // 0..1
    if (h < 0.0) h += 1.0;   // roll one round

    return <h, s, v>;
}

// uses link or face numbers
integer getTouchedPart() {
    return llDetectedTouchFace(0);
}

// make the conversion to take in account the extra 2% on the picker/slider,
// than the actual covered zone
vector marker2palette(vector coord) {
    // for each axis, limit the range to 98% of the size
    // and then add the 2% to get the real value
    if (coord.x <= 0.01) coord.x = 0.0;
    else if (coord.x >= 0.99) coord.x = 0.999999;
    else coord.x = (coord.x - 0.01) * 1.02;
    if (coord.y <= 0.01) coord.y = 0.0;
    else if (coord.y >= 0.99) coord.y = 0.999999;
    else coord.y = (coord.y - 0.001)* 1.02;
    return coord;
}

setHSV(integer part, vector coord) {
    vector real = marker2palette(coord);
    if (part == PART_SLIDER) HSV.x = real.x; // warning: if made vertical, should be changed here
    else if (part == PART_PICKER) HSV = <HSV.x, real.x, real.y>;
    updateUI(part);
}

updateUI(integer part) {
    list r;
    if (part == 0 || part == PART_SLIDER) {
        float pos = 1.0 - HSV.x;
        pos -= (pos * 0.02);
        r += [ PRIM_TEXTURE, PART_SLIDER ]
          + llListReplaceList(llGetLinkPrimitiveParams(LINK_THIS, [PRIM_TEXTURE, PART_SLIDER]), [<pos, 0.0, 0.0>], 2, 2)
          + [ PRIM_COLOR, PART_CURHUE, hsv2rgb(<HSV.x, 1.0, 1.0>), 1.0 ];
    }
    if (part == 0 || part == PART_PICKER) {
        float sat = HSV.y;
        float val = HSV.z;
        if (sat <= 0.01) sat = 0.010000;
        else if (sat >= 0.99) sat = 0.990000;
        if (val <= 0.01) val = 0.010000;
        else if (val >= 0.99) val = 0.990000;
        r += [ PRIM_TEXTURE, PART_PICKER ]
          + llListReplaceList(llGetLinkPrimitiveParams(LINK_THIS, [PRIM_TEXTURE, PART_PICKER]), [<0.5-sat, 0.5-val, 0.0>], 2, 2);
    }
    llSetLinkPrimitiveParamsFast(LINK_THIS, r + [ PRIM_COLOR, PART_PREVIEW, hsv2rgb(HSV), 1.0 ]);
}

sendColor(integer reason) {
    vector col = HSV;
    if (!sendHSV) col = hsv2rgb(col);
    llMessageLinked(sendTo, reason, (string)col, "ColorPicker");
}

default {
    state_entry() {
        updateUI(0);
    }
    link_message(integer sender, integer n, string str, key id) {
        if (sender == LINK_THIS || (string)id != "ColorPicker") return;
        if (n == 0) {
            // init
            list p = llParseString2List(str, ["~", "="], []);
            n = llGetListLength(p) - 2;
            for (; n > -1; n -= 2) {
                str = llList2String(p, n);
                if (str == "rgb") {
                    HSV = rgb2hsv((vector)llList2String(p, n+1));
                    updateUI(0);
                }
                else if (str == "hsv") {
                    HSV = (vector)llList2String(p, n+1);
                    updateUI(0);
                }
                else if (str == "sliderColor") {
                    llSetColor((vector)llList2String(p, n+1), PART_SLIDER);
                }
                else if (str == "public") {
                    ownerOnly = (integer)(llList2String(p, n+1) == "0");
                }
                else if (str == "selectOnly") {
                    selectOnly = (integer)(llList2String(p, n+1) == "1");
                }
                else if (str == "sendHSV") {
                    sendHSV = (integer)(llList2String(p, n+1) == "1");
                }
                else if (str == "sendTo") {
                    integer to = (integer)llList2String(p, n+1);
                    if (to > 0) sendTo = to;
                    else sendTo = LINK_ALL_OTHERS;
                }
            }
        }
        else if (n == 3) {
            sendColor(-3);
        }
    }
    touch_start(integer n) {
        if (llDetectedKey(0) != llGetOwner() && ownerOnly == TRUE) return;
        if (toucher == NULL_KEY || llGetTime() > 0.25) {
            integer part = getTouchedPart();
            toucher = llDetectedKey(0);
            touchedPart = part;
            if (part == PART_PICKER || part == PART_SLIDER) {
                coordPre = llDetectedTouchST(0);
                setHSV(part, coordPre);
            }
        }
    }
    touch(integer n) {
        if (toucher == llDetectedKey(0) && llGetTime() > (1.0 / UPDATE_PER_SECOND)) {
            vector coord = llDetectedTouchST(0);
            if (coord == coordPre) return;  // no move

            integer part = getTouchedPart();
            if (part == touchedPart && coord != TOUCH_INVALID_TEXCOORD) {
                coordPre = coord;
            }
            else {
                coord = coordPre;
                part = touchedPart;
            }
            setHSV(part, coord);
            if (!selectOnly) sendColor(-1);
        }
    }
    touch_end(integer n) {
        if (toucher == llDetectedKey(0)) {
            n = getTouchedPart();
            if (n == PART_PREVIEW) sendColor(2);
            else sendColor(1);
        }
        for (--n; n >= 0; --n) {
            if (llDetectedKey(0) == toucher) {
                toucher = NULL_KEY;
                return;
            }
        }
    }
}
