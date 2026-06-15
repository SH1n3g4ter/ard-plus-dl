#!/usr/bin/env bash
set -e

scriptdir="$(dirname "$0")"
curlBin=$(command -v curl)
FILE=ard-plus-token
USERAGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"

function usage {
  echo "There is two ways to run this script:"
  echo "  1. input arguments:"
  echo "    ./ard-plus-dl <ard-plus-url> <username> <password>"
  echo "  2. with a environment file, with the following entries:"
  echo "    --- .env ---"
  echo "    ARD_USER=your@email.com"
  echo "    ARD_PW=yourpw"
  echo "    -----------------"
  echo "    then run the script as follows:"
  echo "    ./ard-plus-dl --config </path/to/config/.env> <ard-plus-url>"
  echo "    If the environment file (.env) is located in the script directory the --config flag may be obmitted"
  echo "    There is a template file (.env.template)"
  echo ""
  echo "flags:"
  echo "  -a|--automatic    will automatically select and download the episode/season"
  echo "  -c|--config       path to environment file"
  echo "     --debug        enable debug prints"
  echo "     --help         prints this help page"
  echo "  -o|--outdir       output directory"
  echo "  -s|--skip         will skip episodes to download"
}

# requirement checks
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "missing ffmpeg"
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "missing jq"
    exit 1
fi
if ! command -v yt-dlp >/dev/null 2>&1; then
    echo "missing yt-dlp"
    exit 1
fi

# parse input parameter
automatic_download=0
skip=1
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -a|--automatic)
      automatic_download=1
      shift # past argument
      ;;
    -s|--skip)
      skip="$2"
      shift
      shift
      ;;
    -c|--config)
      config_path="$2"
      shift
      shift
      ;;
    -o|--outdir)
      outdir="$2"
      shift
      shift
      ;;
    --help)
      usage
      exit
      ;;
    --debug)
      DEBUG="YES"
      shift
      ;;
    -*|--*)
      echo "Unknown option $1"
      usage
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

debug() {
    if [ "$DEBUG" = "YES" ]; then
        echo "$1"
    fi
}

if [ -n "$config_path" ]; then
    source "$config_path"
elif [ -f "$scriptdir/.env" ]; then
    source "$scriptdir/.env"
fi
if [ -z "$outdir" ]; then
    if [ -n "$OUTDIR" ]; then
        outdir="$OUTDIR"
    else
        outdir="."
    fi
fi

ardPlusUrl=$1
if [ -n "$2" ]; then
    username="$2"
else
    username="$ARD_USER"
fi
if [ -n "$3" ]; then
    password="$3"
else
    password="$ARD_PW"
fi

movieId=''
token=''
showPath=$(echo $ardPlusUrl | rev | cut -d "/" -f1 | rev)
showId=$(echo $showPath | cut -d "-" -f1)

if [ -z "$ardPlusUrl" ]; then
    usage
    exit 1
fi

if [[ -z "$username" || -z "$password" ]]; then
  usage
  exit 1
fi

content_result=$(mktemp)

# login only if necessary
login() {
    encoded_username=$(printf %s "$username" | jq -s -R -r @uri)
    encoded_password=$(printf %s "$password" | jq -s -R -r @uri)
    token=$("$curlBin" -is 'https://auth.ardplus.de/auth/login?plainRedirect=true&redirectURL=https%3A%2F%2Fwww.ardplus.de%2Flogin%2Fcallback&errorRedirectURL=https%3A%2F%2Fwww.ardplus.de%2Fanmeldung%3Ferror%3Dtrue' \
    -H 'authority: auth.ardplus.de' \
    -H 'content-type: application/x-www-form-urlencoded' \
    -H 'origin: https://www.ardplus.de' \
    -H 'referer: https://www.ardplus.de/' \
    -H "user-agent: ${USERAGENT}" \
    --data-raw "username=${encoded_username}&password=${encoded_password}" | grep -i authorization | awk '{print $3}' | tr -d \\r)
    tokenType=$(echo $token | cut -f1 -d "." | base64 -d | jq -r '.typ')
    if [[ "$tokenType" == "JWT" ]]; then
        echo $token | tr -d \\r > $FILE
        debug "login successful"
    else
        echo "Login not possible! Please check credentials and subscription for user $username."
        exit 1
    fi
}

# cleanup after each episode and at the end
cleanup() {
    deleteToken=$("$curlBin" -s 'https://token.ardplus.de/token/session/playback/delete' \
    -H 'authority: token.ardplus.de' \
    -H 'content-type: application/json' \
    -H "cookie: sid=$token" \
    -H 'origin: https://www.ardplus.de' \
    -H 'referer: https://www.ardplus.de/' \
    -H "user-agent: ${USERAGENT}" \
    --data-raw "{\"contentId\":\"$movieId\",\"contentType\":\"CmsMovie\"}" \
    --compressed)
}

# get authorization for content
auth() {
    auth=$("$curlBin" -s 'https://token.ardplus.de/token/session' \
        -H 'authority: token.ardplus.de' \
        -H 'content-type: application/json' \
        -H "cookie: sid=$token" \
        -H 'origin: https://www.ardplus.de' \
        -H 'referer: https://www.ardplus.de/' \
        -H "user-agent: ${USERAGENT}" \
        --data-raw "{\"contentId\":\"$movieId\",\"contentType\":\"CmsEpisode\",\"download\":false,\"appInfo\":{\"platform\":\"web\",\"appVersion\":\"1.0.0\",\"build\":\"web\",\"bundleIdentifier\":\"web\"},\"deviceInfo\":{\"isTouchDevice\":false,\"isTablet\":false,\"isFireOS\":false,\"appPlatform\":\"web\",\"isIOS\":false,\"isCastReceiver\":false,\"isSafari\":false,\"isFirefox\":false}}" \
        --compressed)
    urlParam=$(echo ${auth} | jq -r '.authorizationParams')
    echo "$urlParam"
}

# intercept CTRL+C click to clean up before exit
term() {
    echo "CTRL+C pressed. Cleanup and exit!"
    cleanup
    rm -f $content_result
    exit 0
}
trap term SIGINT

# perform login
if [ -f "$FILE" ]; then
    # Using cached token
    token=$(<$FILE)
else
    # Log in once
    login $username $password
fi

# check if token is valid
movieId="a0S010000007GcX"
urlParam=$( auth )
if [[ "$urlParam" == null ]]; then
    login $username $password
    token=$(<$FILE)
    if [[ -z "$token" ]]; then
        echo "Login not possible! Please check credentials and subscription for user $username."
        exit 0
    fi
fi
cleanup

# get requested content
contentUrl="https://data.ardplus.de/ard/graphql?extensions=%7B%22persistedQuery%22%3A%7B%22version%22%3A1%2C%22sha256Hash%22%3A%2240d7cbfb79e6675c80aae2d44da2a7f74e4a4ee913b5c31b37cf9522fa64d63b%22%7D%7D&variables=%7B%22movieId%22%3A%22$showId%22%2C%22externalId%22%3A%22%22%2C%22slug%22%3A%22%22%2C%22potentialMovieId%22%3A%22%22%7D"
seasonsStatus=$("$curlBin" -s -o $content_result -w "%{http_code}" "${contentUrl}" \
    -H 'authority: data.ardplus.de' \
    -H 'content-type: application/json' \
    -H "cookie: sid=$token" \
    -H 'origin: https://www.ardplus.de' \
    -H 'referer: https://www.ardplus.de/' \
    -H "user-agent: ${USERAGENT}")
if [[ $seasonsStatus != "200" ]]; then
    #retry once
    echo "Couldn't get season details. Trying again!"
    sleep 2
    seasonsStatus=$("$curlBin" -s -o $content_result -w "%{http_code}" "${contentUrl}" \
    -H 'authority: data.ardplus.de' \
    -H 'content-type: application/json' \
    -H "cookie: sid=$token" \
    -H 'origin: https://www.ardplus.de' \
    -H 'referer: https://www.ardplus.de/' \
    -H "user-agent: {USERAGENT}")
    contentResult=$(cat $content_result)
else
    contentResult=$(cat $content_result)
fi

debug "contentResult: $contentResult"

# check whether content is movie or series
movie=$(echo "$contentResult" | jq '.data.movie')
tvshow=$(echo "$contentResult" | jq '.data.series')

if [[ "$movie" != null ]]; then
    movieId=$(echo "$movie" | jq -r '.id')
    name=$(echo "$movie" | jq -r '.title')
    videoUrl=$(echo "$movie" | jq -r '.videoSource.dashUrl')
    year=$(echo "$movie" | jq -r '.productionYear')
    filename="${name/\// } (${year})/${name/\// }"
    urlParam=$( auth )
    downloadUrl=${videoUrl}?${urlParam}
    echo "Lade Film ${filename}..."
    savepath="${outdir}/${filename}"
    yt-dlp --quiet --progress --no-warnings --audio-multistreams -f "bv+mergeall[vcodec=none]" --sub-langs "en.*,de.*" --embed-subs --merge-output-format mp4 ${downloadUrl} -o "$savepath"
elif [[ "$tvshow" != null ]]; then
    requestedShow=$(echo "$contentResult" | jq -r '.data.series.title')
    seasonIds=$(echo "$contentResult" | jq '[.data.series.seasons.nodes[] | { season: .seasonInSeries, seasonId: .id, title: .title }]')
    seasonCount=$(echo "$contentResult" | jq '[.data.series.seasons.nodes[] | { season: .seasonId }] | length')
    seasonOutput=$(echo "$seasonIds" | jq '[.[] | { Option: .season, Titel: .title }]' | jq -r '(.[0]|keys_unsorted|(.,map(length*"-"))),.[]|map(.)|@tsv'|column -ts $'\t')
    echo -e "\nGewünschte Serie: $requestedShow\n"
    echo -e "$seasonOutput\n"

    if [ $automatic_download -eq 0 ]
    then
        echo -n "Welche Staffel möchtest du runterladen? "
        read -r selectedSeasonList
    else
        selectedSeasonList=$(seq 1 $seasonCount)
    fi

    # loop over all seasons
    for selectedSeason in $selectedSeasonList
    do
        selectedSeasonId=$(echo "$seasonIds" | jq -r --argjson index 1 ".[$((selectedSeason - 1))].seasonId")

        seasonData=$("$curlBin" -s "https://data.ardplus.de/ard/graphql?extensions=%7B%22persistedQuery%22%3A%7B%22version%22%3A1%2C%22sha256Hash%22%3A%22134d75e1e68a9599d1cdccf790839d9d71d2e7d7dca57d96f95285fcfd02b2ae%22%7D%7D&variables=%7B%22seasonId%22%3A%22$selectedSeasonId%22%7D&operationName=EpisodesInSeasonData" \
        -H 'authority: data.ardplus.de' \
        -H 'content-type: application/json' \
        -H "cookie: sid=$token" \
        -H 'origin: https://www.ardplus.de' \
        -H 'referer: https://www.ardplus.de/' \
        -H "user-agent: ${USERAGENT}")
        episodes=$(echo $seasonData | jq '[.data.episodes.nodes[] | { id: .id, episodeNo: .episodeInSeason, title: .title, videoUrl: .videoSource.dashUrl }]')
        amount=$(echo $episodes | jq '. | length')
        echo -e "\nStaffel $selectedSeason hat $amount Folgen."
        selectedSeasonFormatted=$(printf '%02d\n' "$selectedSeason")

        if [[ $skip != "1" ]]; then
            echo "Überspringe $skip Episode(n)."
            skip=$((skip + 1))
        fi

        # loop over all episodes and download each
        while read episode
        do
            movieId=$(echo "$episode" | jq -r '.id')
            name=$(echo "$episode" | jq -r '.title')
            videoUrl=$(echo "$episode" | jq -r '.videoUrl')
            episode=$(echo "$episode" | jq -r '.episodeNo')
            filename="${requestedShow/\// }/Season ${selectedSeasonFormatted}/${requestedShow/\// } S${selectedSeasonFormatted}E$(printf '%02d\n' $episode) - ${name}"
            urlParam=$( auth )
            downloadUrl=${videoUrl}?${urlParam}
            echo "Lade ${filename}..."
            savepath="${outdir}/${filename}"
            yt-dlp --quiet --progress --no-warnings --audio-multistreams -f "bv+mergeall[vcodec=none]" --sub-langs "en.*,de.*" --embed-subs --merge-output-format mp4 ${downloadUrl} -o "$savepath"
            cleanup
        done < <(echo "$episodes" | sed 's/\\"//g' | jq -c '.[]' | tail -n +$skip)

    done

elif [[ "$ardPlusUrl" == *"tatort"* ]]; then
    tatortCity=$(echo $showPath | cut -d "-" -f2)
    # get all episodes per city
    tatortResponse=$("$curlBin" -s "https://www.ardplus.de/kategorie/$showPath" \
    --header 'authority: data.ardplus.de' \
    --header 'content-type: application/json' \
    --header "cookie: sid=$token" \
    --header 'origin: https://www.ardplus.de' \
    --header 'referer: https://www.ardplus.de/' \
    --header "user-agent: ${USERAGENT}")

    tatortCityEpisodes=$(echo $tatortResponse | perl -0777 -ne 'print "$1\n" if /<script type="application\/ld\+json">\s*(.*?)\s*<\/script>/s')

    amount=$(echo $tatortCityEpisodes | jq '.itemListElement | length')
    cityCapitalized=$(echo ${tatortCity} | awk '{$1=toupper(substr($1,0,1))substr($1,2)}1')
    echo "Der Tatort ${cityCapitalized} hat $amount Episoden."
    if [ $automatic_download -eq 0 ]
    then
        echo -n "Wie viele Episoden möchtest du überspringen? (0=alle laden) "
        read -r skip
        echo "Überspringe $skip Episode(n)."
    else
        skip=0
    fi
    skip=$((skip + 1))

    # loop over all episodes and download each
    while read episode
    do
        episodeId=$(echo "$episode" | jq -r '.item.url' | sed -E 's#.*/details/([^/-]+).*#\1#')
        episodeUrl="https://data.ardplus.de/ard/graphql?extensions=%7B%22persistedQuery%22%3A%7B%22version%22%3A1%2C%22sha256Hash%22%3A%2240d7cbfb79e6675c80aae2d44da2a7f74e4a4ee913b5c31b37cf9522fa64d63b%22%7D%7D&variables=%7B%22movieId%22%3A%22$episodeId%22%2C%22externalId%22%3A%22%22%2C%22slug%22%3A%22%22%2C%22potentialMovieId%22%3A%22%22%7D"

        episodeDetailsStatus=$("$curlBin" -s -o current-tatort-episode.txt -w "%{http_code}" "${episodeUrl}" \
            -H 'authority: data.ardplus.de' \
            -H 'content-type: application/json' \
            -H "cookie: sid=$token" \
            -H 'origin: https://www.ardplus.de' \
            -H 'referer: https://www.ardplus.de/' \
            -H "user-agent: ${USERAGENT}")

        if [[ $episodeDetailsStatus != "200" ]]; then
            #retry once
            echo "Couldn't get episode details. Trying again!"
            sleep 2
            episodeDetailsStatus=$("$curlBin" -s -o current-tatort-episode.txt -w "%{http_code}" $episodeUrl \
            -H 'authority: data.ardplus.de' \
            -H 'content-type: application/json' \
            -H "cookie: sid=$token" \
            -H 'origin: https://www.ardplus.de' \
            -H 'referer: https://www.ardplus.de/' \
            -H "user-agent: ${USERAGENT}" \
            --compressed)
            episodeDetails=$(cat current-tatort-episode.txt)
        else
            episodeDetails=$(cat current-tatort-episode.txt)
        fi

        movieId=$(echo "$episodeDetails" | jq -r '.data.movie.id')
        name=$(echo "$episodeDetails" | jq -r '.data.movie.title')
        videoUrl=$(echo "$episodeDetails" | jq -r '.data.movie.videoSource.dashUrl')
        year=$(echo "$episodeDetails" | jq -r '.data.movie.productionYear')
        customData=$(echo "$episodeDetails" | jq -r '.data.movie.customData')
        episode=$(echo "$customData" | jq -r '.episodeProductionNumber')
        team=$(echo "$customData" | jq -r '.team')
        city=$(echo "$customData" | jq -r '.location')
        filename="Tatort ${city}"
        if [[ -n "$team" ]];
        then
            filename="$filename (${team})"
        fi
        if [[ "$episode" != null ]];
        then
            filename="$filename - Folge ${episode}"
        fi
        filename="$filename - ${name} (${year})"
        urlParam=$( auth )
        downloadUrl=${videoUrl}?${urlParam}
        echo "Lade ${filename}..."
        savepath="${outdir}/${filename}"
        yt-dlp --quiet --progress --no-warnings --audio-multistreams -f "bv+mergeall[vcodec=none]" --sub-langs "en.*,de.*" --embed-subs --merge-output-format mp4 ${downloadUrl} -o "$savepath"
        cleanup
        sleep 1
    done < <(echo "$tatortCityEpisodes" | jq -c '.itemListElement[]' | tail -n +$skip )
else
    echo "invalid content"
fi
cleanup
