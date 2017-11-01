ps -eo rss,pid,user,command | sort -rn | awk '$1 > 10000' | awk '
{
 hr[1024**2]="GB"; 
 hr[1024]="MB";
 for (x=1024**3; x>=1024; x/=1024) {
    if ($1>=x) { printf ("%-6.2f %s ", $1/x, hr[x]); break }
 } 
} 
{ printf ("%-6s %-10s ", $2, $3) }
{ 
    for ( x=4 ; x<=NF ; x++ ) { 
       printf ("%s ",$x) 
    }
    printf ("\n")
}
 ' | sed '1!G;h;$!d'

echo ""
echo ""

if [ ! -f /usr/bin/ps_mem.py ]; then
    sudo wget -O /usr/bin/ps_mem.py https://raw.githubusercontent.com/pixelb/ps_mem/master/ps_mem.py && chmod +x /usr/bin/ps_mem.py
fi

sudo /usr/bin/ps_mem.py -S

echo ""
echo ""

free -m | awk 'NR==2{printf "Memory Usage: %.2fGB/%.2fGB (%.2f%%)\n", $3/1024,$2/1024,$3/$2*100 }'

echo ""
