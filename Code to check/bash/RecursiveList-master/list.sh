#!/bin/bash 
function tabs()
{
	local result=''
	for i in `seq 1 $1`; do
		result="--$result"
	done
	echo $result
}
traverse()
{
	line=`tabs $1`
	for file in *; do
		if [ -d "$file" ]; then
			echo "$line$file/"
			(cd "$file"; traverse $((1+$1)))
		elif [ -e "$file" ]; then
			echo "$line$file"
		fi
	done
}
(cd $1; traverse 0)
