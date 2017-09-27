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
