#!/bin/bash
 # Copyright (c) 2011 Josh Schreuder
 # http://www.postteenageliving.com
 #
 # Permission is hereby granted, free of charge, to any person obtaining a copy
 # of this software and associated documentation files (the "Software"), to deal
 # in the Software without restriction, including without limitation the rights
 # to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 # copies of the Software, and to permit persons to whom the Software is
 # furnished to do so, subject to the following conditions:
 #
 # The above copyright notice and this permission notice shall be included in
 # all copies or substantial portions of the Software.
 #
 # THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 # IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 # FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 # AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 # LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 # OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 # THE SOFTWARE.
 # ********************************
 # *** OPTIONS
 # ********************************
 # Set this to 'yes' to save a description (to ~/description.txt) from ngeo page
 #
 # I can’t see where this line is used anywhere in the script, so let’s comment it out
 # GET_DESCRIPTION="yes"
 #
 # Set this to the directory you want pictures saved
 PICTURE_DIR=~/Pictures/Wallpapers/NatGeo
 if [ ! -d $PICTURES_DIR ]; then
   mkdir -p $PICTURES_DIR
 fi
 sleep 1
 # ********************************
 # *** FUNCTIONS
 # ********************************
 function get_page {
   echo "Downloading page to find image"
   wget http://photography.nationalgeographic.com/photography/photo-of-the-day/ --quiet -O- 2> /dev/null |
   grep -m 1 http://images.nationalgeographic.com/.*.jpg -o > /tmp/pic_url
   wget http://photography.nationalgeographic.com/photography/photo-of-the-day/ --quiet -O- 2> /dev/null |
   grep -m 1 http://images.nationalgeographic.com/.*1600x1200.*.jpg -o > /tmp/pic_url2
 }
 function clean_up {
   # Clean up
   echo "Cleaning up temporary files"
   if [ -e "/tmp/pic_url" ]; then
     rm /tmp/pic_url
   fi
   if [ -e "/tmp/pic_url2" ]; then
     rm /tmp/pic_url2
   fi
   if [ -f "~/tmp/NatGeo.edc" ]; then
     rm -f ~/tmp/NatGeo.edc
   fi
}
  function make_js {
    js=$(mktemp)
    cat > $js <<_EOF
      var wallpaper = "$PICTURES_DIR/${TODAY}_ngeo.jpg";
      var activity = activities()[0];
      activity.currentConfigGroup = new Array("Wallpaper", "image");
      activity.writeConfig("wallpaper", wallpaper);
      activity.writeConfig("userswallpaper", wallpaper);
      activity.reloadConfig();
_EOF
}
 function kde_wallpaper {
   make_js
   qdbus org.kde.plasma-desktop /MainApplication loadScriptInInteractiveConsole $js > /dev/null
   # sleep 2
   xdotool search --name "Desktop Shell Scripting Console – Plasma Desktop Shell" windowactivate key ctrl+e key ctrl+w
   rm -f "$js"
   dbus-send --dest=org.kde.plasma-desktop /MainApplication org.kde.plasma-desktop.reparseConfiguration
   dbus-send --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig
   dbus-send --dest=org.kde.kwin /KWin org.kde.KWin.reloadConfig
   # kbuildsycoca4 2>/dev/null && kquitapp plasma-desktop 2>/dev/null ; kstart plasma-desktop > /dev/null 2>&1
 }
 function xfce_wallpaper {
   xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/image-path -s "$PICTURES_DIR/${TODAY}_ngeo.jpg"
 }
 function lxde_wallpaper {
   pcmanfm -w "$PICTURES_DIR/${TODAY}_ngeo.jpg"
 }
 function mate_wallpaper {
   gsettings set org.mate.background picture-filename "$PICTURES_DIR/${TODAY}_ngeo.jpg"
 }
 function e17_wallpaper {
   OUTPUT_DIR=~/.e/e/backgrounds
   FileName=$PICTURES_DIR/${TODAY}_ngeo.jpg
   edcFile=~/tmp/NatGeo.edc

   echo 'images { image: "'$FileName'" LOSSY 90; }' > $edcFile
   echo 'collections {' >> $edcFile
   echo 'group { name: "e/desktop/background";' >> $edcFile
   echo 'data { item: "style" "4"; }' >> $edcFile
   echo 'data.item: "noanimation" "1";' >> $edcFile
   echo 'max: 990 742;' >> $edcFile
   echo 'parts {' >> $edcFile
   echo 'part { name: "bg"; mouse_events: 0;' >> $edcFile
   echo 'description { state: "default" 0.0;' >> $edcFile
   echo 'aspect: 1.334231806 1.334231806; aspect_preference: NONE;' >> $edcFile
   echo 'image { normal: "'$FileName'";  scale_hint: STATIC; }' >> $edcFile
   echo '} } } } }' >> $edcFile
   edje_cc -nothreads ~/tmp/NatGeo.edc -o $OUTPUT_DIR/NatGeo.edj
   sleep 2 && rm -f ~/tmp/NatGeo.edc
   echo 'Enlightenment e17 NatGeo.edj file created'
   enlightenment_remote -desktop-bg-del 0 0 -1 -1
   enlightenment_remote -desktop-bg-add 0 0 -1 -1 $OUTPUT_DIR/NatGeo.edj;
 }
 function usage {
   printf "%s\n%s\n\n%s\n%s\n\n%s\n\n%s" \
   "NatGeo-POD will download the National Geographic Picture Of The Day,"\
   "and (optionally) set that picture as the new wallpaper."\
   "Written and drawn from several sources by Paul Arnote for PCLinuxOS."\
   "Originally published in The PCLinuxOS Magazine (http://pclosmag.com), Sept. 2013 issue."\
   "Works for KDE4, Xfce, LXDE, Mate and e17 desktops."\
   "Usage: $0 [arguments]"\

   printf "\n %s\t%s" \
   "-h, --help" "This help text"
   printf "\n %s\t\t%s" \
   "-d" "Download pictures ONLY"
   printf "\n %s\t\tSetup for the %s" \
   "--xfce"	"XFCE4 Desktop"\
   "--mate"	"Mate Desktop"\
   "--lxde"	"LXDE Desktop"\
   "--kde4"	"KDE4 Desktop"\
   "--e17"	"Enlightenment Desktop"
   printf "\n"
 }
 # ********************************
 # *** MAIN
 # ********************************
 if [ "$1" == "--help" ] || [ "$1" == "-h" ] || [ "$1" == "" ]; then
   usage
   exit
 fi
 echo "===================="
 echo "== NGEO Wallpaper =="
 echo "===================="
 # Set date
 TODAY=$(date +'%Y%m%d')
 # If we don't have the image already today
 if [ ! -e $PICTURES_DIR/${TODAY}_ngeo.jpg ]; then
   echo "We don't have the picture saved, save it"
   get_page
   # Got the link to the image
   PICURL=`/bin/cat /tmp/pic_url`
   PICURL2=`/bin/cat /tmp/pic_url2`
   echo "Picture URL is: ${PICURL}"
   echo "Picture URL 2 is: ${PICURL2}"
   echo "Downloading images"
   wget --quiet $PICURL -O $PICTURES_DIR/${TODAY}_ngeo.jpg
   wget --quiet $PICURL2 -O $PICTURES_DIR/${TODAY}-1600x1200_ngeo.jpg
   if [ "$1" != "-d" ]; then
     echo "Setting image as wallpaper"
   fi
   # Uncomment (remove the #) in front of the appropriate command for your particular desktop environment
   # For Xfce
   if [ "$1" == "--xfce" ]; then
     xfce_wallpaper
   fi
   # For LXDE
   if [ "$1" == "--lxde" ]; then
     lxde_wallpaper
   fi
   # For Mate
   if [ "$1" == "--mate" ]; then
     mate_wallpaper
   fi
   # For KDE4
   if [ "$1" == "--kde4" ]; then
     kde_wallpaper
   fi
   # For e17
   if [ "$1" == "--e17" ]; then
     e17_wallpaper
   fi
   #
 # Else if we have it already, check if it's the most updated copy
 else
   get_page
   # Got the link to the image
   PICURL=`/bin/cat /tmp/pic_url`
   PICURL2=`/bin/cat /tmp/pic_url2`
   echo "Picture URL is: ${PICURL}"
   echo "Picture URL 2 is: ${PICURL2}"
   # Get the filesize
   SITEFILESIZE=$(wget --spider $PICURL 2>&1 | grep Length | awk '{print $2}')
   FILEFILESIZE=$(stat -c %s $PICTURES_DIR/${TODAY}_ngeo.jpg)
   # If the picture has been updated
   if [ $SITEFILESIZE != $FILEFILESIZE ]; then
     echo "The pictures have been updated ... getting updated copy"
     rm $PICTURES_DIR/${TODAY}_ngeo.jpg
     rm $PICTURES_DIR/${TODAY}-1600x1200_ngeo.jpg
     # Got the link to the image
     PICURL=`/bin/cat /tmp/pic_url`
     PICURL2=`/bin/cat /tmp/pic_url2`
     echo "Downloading images"
     wget --quiet $PICURL -O $PICTURES_DIR/${TODAY}_ngeo.jpg
     wget --quiet $PICURL2 -O $PICTURES_DIR/${TODAY}-1600x1200_ngeo.jpg
   if [ "$1" != "-d" ]; then
     echo "Setting image as wallpaper"
   fi
   # Uncomment (remove the #) in front of the appropriate command for your particular desktop environment
   # For Xfce
   if [ "$1" == "--xfce" ]; then
     xfce_wallpaper
   fi
   # For LXDE
   if [ "$1" == "--lxde" ]; then
     lxde_wallpaper
   fi
   # For Mate
   if [ "$1" == "--mate" ]; then
     mate_wallpaper
   fi
   # For KDE4
   if [ "$1" == "--kde4" ]; then
     kde_wallpaper
   fi
   # For e17
   if [ "$1" == "--e17" ]; then
     e17_wallpaper
   fi
   #
   # If the picture is the same
   else
     echo "Picture is the same, finishing up"
   if [ "$1" != "-d" ]; then
     echo "Setting image as wallpaper"
   fi
   # For LXDE
   if [ "$1" == "" ] || [ "$1" == "--lxde" ]; then
     lxde_wallpaper
   fi
   # For Xfce
   if [ "$1" == "--xfce" ]; then
     xfce_wallpaper
   fi
   if [ "$1" == "--mate" ]; then
     mate_wallpaper
   fi
   # For KDE4
   if [ "$1" == "--kde4" ]; then
     kde_wallpaper
   fi
   # For e17
   if [ "$1" == "--e17" ]; then
     e17_wallpaper
   fi
   #
   fi
 fi
 clean_up
