#/bin/bash

hugo --minify
docker-compose -f "docker-compose.yml" up -d && docker-compose start http
attempt_counter=0
max_attempts=5

until $(curl --output /dev/null --silent --head --fail http://localhost/cv); do
    if [ ${attempt_counter} -eq ${max_attempts} ];then
      echo "Max attempts reached"
      exit 1
    fi

    printf '.'
    attempt_counter=$(($attempt_counter+1))
    sleep 10
done

docker run \
--network container:http \
-v $(pwd):/usr/src/app \
zenika/alpine-chrome:102 --no-sandbox --no-pdf-header-footer --print-to-pdf=public/files/cv.pdf --hide-scrollbars \
http://http/cv

docker-compose stop http
docker-compose -f "docker-compose.yml" down