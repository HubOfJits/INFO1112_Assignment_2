#!/bin/bash


IP=$(ifconfig | grep 'inet addr' | grep -v '127.0.0.1' | cut -d':' -f2 | cut -d' ' -f1)

nc -l 1234 &
PROBE_PID=$!
sleep 1
PORT=$(ss -ltn | grep LISTEN | cut -d':' -f2 | cut -d' ' -f1)
kill "$PROBE_PID"

echo "The server is running at $IP, port=$PORT"

reply=/tmp/reply_command
rm -f "$reply"
mkfifo "$reply"

connections=/tmp/connections.log
: > "$connections"

reject_lists=/tmp/reject.list
: > "$reject_lists"

# Points of Interest
#name|latitude|longitude

poi_locations=/tmp/pois.txt
cat > "$poi_locations" <<'EOF'
Fisher Library|-33.8868|151.1893
Victoria Park|-33.8848|151.1919
Manning House|-33.8866|151.1881
The Quadrangle|-33.8857|151.1893
Charles Perkins Centre|-33.8881|151.1828
Redfern Station|-33.8917|151.1985
Holme Building|-33.8873|151.1889
Central Station|-33.8832|151.2063
SIT Building (J12)|-33.8884|151.1940
Broadway Shopping Centre|-33.8838|151.1940
EOF

RADIUS=300

handle_request() {
    request="$1"

    case "$request" in
        assignment)

            assignment_url="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"
            if ! curl -sfL "$assignment_url" -o /tmp/unit.html; then
                echo "ERROR: downloading unit page unsuccessful ($UNIT_URL)" >&2
                echo "ERROR: downloading unit page unsuccessful"

            elif ! html2text /tmp/unit.html > /tmp/unit.txt; then
                echo "ERROR: could not convert the unit page to text" >&2
                echo "ERROR: could not convert the unit page to text"

            elif ! grep -m1 -A2 "Assignment 2" /tmp/unit.txt >&2; then
                echo "ERROR: 'Assignment 2' not found on the unit page" >&2
                echo "ERROR: 'Assignment 2' not found on the unit page"

            else
                row=$(html2text -width 1000 /tmp/unit.html | grep -m1 -A1 "Assignment 2")
                title=$(echo "$row" | grep -o "Assignment [0-9]*" | head -1)
                topic=$(echo "$row" | grep -o -- "- [A-Za-z]*" | head -1 | cut -d' ' -f2)
                points=$(echo "$row" | grep -o "[0-9]*%" | head -1 | tr -d '%')
                due=$(echo "$row" | grep -o "Due date: [0-9]* [A-Za-z]* [0-9]* at [0-9:]*" | head -1 | cut -d' ' -f3,4,5,7)

                if [ -z "$title" ] || [ -z "$topic" ] || [ -z "$points" ] || [ -z "$due" ]; then
                    echo "ERROR: could not find all fields" >&2
                    echo "ERROR: could not build assignment.json"
                else
                    printf '{\n    "title" : "%s",\n    "topic" : "%s",\n    "due_date" : "%s",\n    "points" : %s\n}\n' \
                        "$title" "$topic" "$due" "$points" > /tmp/assignment.json
                    cat /tmp/assignment.json
                fi
            fi
            ;;
        population)


            file_url="https://dbr.abs.gov.au/processedData/csv/STE_1.csv"
            if ! curl -sfL "$file_url" -o /tmp/population.csv; then
                echo "ERROR: could not download population CSV ($file_url)" >&2
                echo "ERROR: could not download the population data"
            else
                tr -d '\r' < /tmp/population.csv > /tmp/population_clean.csv

                year=$(head -1 /tmp/population_clean.csv | tr ',' '\n' | tail -1)
                column=$(head -1 /tmp/population_clean.csv | tr ',' '\n' | grep -n "^${year}$" | cut -d':' -f1)
                population=$(grep "^ERP_P_20," /tmp/population_clean.csv | cut -d',' -f"$column")

                if [ -z "$column" ] || [ -z "$population" ] || [ -z "$year" ]; then
                    echo "ERROR: could not find population" >&2
                    echo "ERROR: could not find population"
                else
                    echo "NSW population ($year): $population" >&2

                    IFS=',' read -r -a YEARS <<< "$(head -1 /tmp/population_clean.csv)"

                    IFS=',' read -r -a VALUES <<< "$(grep '^ERP_P_20,' /tmp/population_clean.csv)"


                    for ((i = 3; i < ${#YEARS[@]}; i++)); do

                        if [ -n "${VALUES[i]}" ]; then

                            echo "${YEARS[i]},${VALUES[i]}"

                        fi

                    done > /tmp/pop_data.csv

                    if [ ! -s /tmp/pop_data.csv ]; then

                        echo "ERROR: no data found" >&2

                        echo "ERROR: no data found"

                    elif ! python3 -c "import matplotlib" 2>/dev/null; then
                        echo "ERROR: matplotlib needed" >&2
                        echo "ERROR: matplotlib needed"
                    else
                        # ---------------------------------------------------------
                        # AI ACKNOWLEDGEMENT: I generated the code below with help
                        # from Claude (Anthropic), as allowed
                        # ---------------------------------------------------------
                        if ! python3 - <<'PY_PLOT' 2>/dev/null
import matplotlib
matplotlib.use("Agg")          
import matplotlib.pyplot as plt

years, pops = [], []
with open("/tmp/pop_data.csv") as f:
    for line in f:
        year, pop = line.strip().split(",")
        years.append(int(year))
        pops.append(int(pop))

plt.figure(figsize=(8, 5))
plt.plot(years, pops, marker="o")
plt.title("NSW Estimated Resident Population")
plt.xlabel("Year")
plt.ylabel("Population")
plt.xticks(years)
plt.ticklabel_format(axis="y", style="plain")
plt.grid(True)
plt.tight_layout()
plt.savefig("/tmp/population.png")
PY_PLOT
                        then
                            echo "ERROR: the Python plot failed" >&2
                            echo "ERROR: could not create population.png"
                        else
                            echo "Sending population.png ($(wc -c < /tmp/population.png) bytes)" >&2
                            cat /tmp/population.png
                        fi
                    fi
                fi
            fi
            ;;
        poi\ *|poi)
            # Everything after "poi " is the place: a name or "lat,lon".
            QUERY="${REQUEST#poi}"
            QUERY="${QUERY# }"
            KNOWN=$(awk -F'|' '{ printf "%s%s", (NR > 1 ? ", " : ""), $1 }' "$POI_FILE")

            if [ -z "$QUERY" ]; then
                echo "ERROR: no POI given" >&2
                echo "ERROR: usage: poi <name>  or  poi <latitude>,<longitude>. Known POIs: $KNOWN"
                return
            fi

            if [[ "$QUERY" =~ ^-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?$ ]]; then
                # Coordinates: split at the comma.
                LAT="${QUERY%,*}"
                LON="${QUERY#*,}"
                SELF=""
            else
                # Name: find the matching line (ignoring upper/lower case).
                MATCH=$(awk -F'|' -v q="$QUERY" 'tolower($1) == tolower(q)' "$POI_FILE" | head -1)
                if [ -z "$MATCH" ]; then
                    echo "ERROR: unknown POI '$QUERY'" >&2
                    echo "ERROR: unknown POI '$QUERY'. Known POIs: $KNOWN"
                    return
                fi
                SELF=$(echo "$MATCH" | cut -d'|' -f1)
                LAT=$(echo "$MATCH" | cut -d'|' -f2)
                LON=$(echo "$MATCH" | cut -d'|' -f3)
            fi

            # Distance from (LAT,LON) to every POI, in metres:
            # 1 degree of latitude ~ 111 km; longitude degrees shrink by cos(latitude).
            # Keep POIs within RADIUS (but not the place itself), nearest first.
            NEIGHBOURS=$(awk -F'|' -v lat="$LAT" -v lon="$LON" -v r="$RADIUS" -v self="$SELF" '
                $1 != self {
                    dy = ($2 - lat) * 111000
                    dx = ($3 - lon) * 111000 * cos(lat * 3.14159265 / 180)
                    d = sqrt(dx * dx + dy * dy)
                    if (d <= r) printf "%d|%s\n", d, $1
                }' "$POI_FILE" | sort -n)

            echo "POI: ${SELF:-$QUERY} ($LAT,$LON), $(echo "$NEIGHBOURS" | grep -c .) neighbour(s) within ${RADIUS} m" >&2

            # Turn "distance|name" lines into JSON objects separated by commas.
            ITEMS=""
            if [ -n "$NEIGHBOURS" ]; then
                ITEMS=$(echo "$NEIGHBOURS" | awk -F'|' '{
                    printf "%s        { \"name\" : \"%s\", \"distance_m\" : %s }", (NR > 1 ? ",\n" : ""), $2, $1
                }')
            fi

            printf '{\n    "poi" : "%s",\n    "latitude" : %s,\n    "longitude" : %s,\n    "radius_m" : %s,\n    "neighbours" : [\n%s\n    ]\n}\n' \
                "${SELF:-$QUERY}" "$LAT" "$LON" "$RADIUS" "$ITEMS" > /tmp/neighbours.json
            cat /tmp/neighbours.json
            ;;
        *)
            echo "ERROR: unknown request '$REQUEST'. Valid requests: assignment, population, poi <name|lat,lon>"
            ;;
    esac
}

connection() {
    ss -tn | awk -v p=":$PORT" -v peer="$1:$2" \
        '$1 == "ESTAB" && $4 ~ (p "$") && $5 == peer { found = 1 } END { exit !found }'
}

client_tracker() {
    ss -tn | awk -v p=":$PORT" -v ip="$1" -v cp="$2" \
        '$1 == "ESTAB" && $4 ~ (p "$") && index($5, ip ":") == 1 && $5 != (ip ":" cp) {
            print ip, substr($5, length(ip) + 2)
        }' >> "$REJECT_LIST"
}

serve_clients() {
    last_connection=""
    while read -r REQUEST; do
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            connection=$(grep "Connection received" "$CONN_LOG" | tail -1)
            [ "$connection" != "$last_connection" ] && break

            sleep 0.1

        done

        last_connection="$connection"
        client_ip=$(echo "$connection" | cut -d' ' -f4)
        client_port=$(echo "$connection" | cut -d' ' -f5)
        echo "Request: $REQUEST" >&2

        if grep -qx "$client_ip                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      $CLIENT_PORT" "$REJECT_LIST"; then
            echo "REJECTED: server busy with request from $CLIENT_IP" >&2
            echo "ERROR: server busy with previous request"
            continue
        fi


        handle_request "$REQUEST" > /tmp/reply.out


        client_tracker "$client_ip" "$client_port"

        if connection "$client_ip" "$client_port"; then
            cat /tmp/reply.out
        else
            echo "(client $client_ip:$client_port disconnected)" >&2
        fi

        while connection "$client_ip" "$client_port"; do

            client_tracker "$client_ip" "$client_port"

            sleep 0.1
        done

        sort -u "$REJECT_LIST" -o "$REJECT_LIST"
    done                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      
}

while true; do
    nc -lkvn "$PORT" < "$reply" 2> >(tee -a "$CONN_LOG" >&2) | serve_clients > "$reply"
done




# AI ACKNOWLEDGEMENT: Claude was used to guide me through this
# assignment. It was used for python plotting and rejecting clients.
# It was also used to debug parts of the program.
