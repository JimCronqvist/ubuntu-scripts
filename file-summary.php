<?php

if(!isset($argv[1]))
{
    echo 'Please use this script by: php file-summary.php /var/www/' . "\n";
    exit(0);
}

class RecursiveDotFilterIterator extends  RecursiveFilterIterator
{
    public function accept()
    {
        return '.' !== substr($this->current()->getFilename(), 0, 1);
    }
}

$array = [];
$exclude_hidden_folders = true;
if($exclude_hidden_folders)
{
    $dir_iterator = new RecursiveDotFilterIterator(new RecursiveDirectoryIterator($argv[1]));
}
else
{
    $dir_iterator = new RecursiveDirectoryIterator($argv[1]);
}

$iterator = new RecursiveIteratorIterator($dir_iterator, RecursiveIteratorIterator::SELF_FIRST);

foreach($iterator as $file)
{
    if($file->isFile())
    {
        $extension = $file->getExtension() == '' ? '[none]' : $file->getExtension();
        echo $file->getPathname() . "\n";
        if(!isset($array[$extension]))
        {
            $array[$extension] = ['count' => 0, 'size' => 0];
        }
        $array[$extension]['count']++;
        $array[$extension]['size'] += $file->getSize();
    }
}

$size = [];
$count = [];
$total_size = 0;
foreach($array as $key => $row)
{
    $total_size += $row['size'];
    $size[$key] = $row['size'];
    $count[$key] = $row['count'];
}
array_multisort($size, SORT_DESC, $count, SORT_DESC, $array);

echo "\n\n";
$mask = "|%15s |%-8.8s |%8.8s |%8.8s |\n";
$dash = str_repeat('-', 15);

printf($mask, $dash, $dash, $dash, $dash);
printf($mask, 'Extension', 'Size', 'Count', 'Percent');
printf($mask, $dash, $dash, $dash, $dash);
foreach($array as $key => $value)
{
    printf($mask, $key, round($value['size']/1024/1024/1024,1) . ' GB', $value['count'], round($value['size']/$total_size*100, 1) . '%');
}
printf($mask, $dash, $dash, $dash, $dash);

?>
