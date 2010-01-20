#!/bin/sh

# Carta Tecnica Regionale Numerica 1:5000
# Download massivo dal sito Regione Friuli-Venezia Giulia.

# Versione lievemente modificata a partire da uno script di Niccolo Rigacci

PREFIX="http://www.siter.regione.fvg.it/cartogdownload"

echo "# Start download: $(date)" >> rinomina.sh

dir="FCN"
test -d "$dir" || mkdir -p "$dir"

for F in 018 \
         030 031 032 033 034 \
         046 047 048 049 050 \
         064 065 066 067 \
         085 086 087 088 \
         106 107 108 109 110 \
         131; do

    for Q1 in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16; do
        for Q2 in 1 2 3 4; do
            # La tavoletta puo' avere due nomi diversi.
            file1="a${F}${Q1}${Q2}g.dat.zip"
            file2="a${F}${Q1}${Q2}g.zip"
            if [ ! -f "$dir/$file1" -a ! -f "$dir/$file2" ]; then
                if ! wget -P "$dir" "$PREFIX/CTRN/FCN/$F/$file1"; then
                    if wget -P "$dir" "$PREFIX/CTRN/FCN/$F/$file2"; then
                        echo "mv $dir/$file2 $dir/$file1" >> rinomina.sh
                    fi
                fi
            fi
        done
    done

done

chmod +x rinomina.sh
./rinomina.sh