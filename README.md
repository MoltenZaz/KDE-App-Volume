This changes the volume of the currenty focused application in kde, i used chatgpt to write the program so im sure theres a much better way to do this, it isn't exactly fast, but it works well enough. It should work on both wayland and x11 applications.

the usage command is: volctrl.sh <up|down> <value>
for example:

volctrl.sh up 10

volctrl.sh down 2

It should try and get the current pid and fallback to detecting the wine64-preloader binary if it can't, then the icon_name "application-games"; this is because I primarily use it for games and that was how I got it to work more consistently.
