find $1 -type d -exec find '{}' -maxdepth 1 ! -iname "files.txt" -type f -fprintf '{}'/FILES.LST "%f\n" \;
find $1 -iname "files.txt" -size 0 -delete
