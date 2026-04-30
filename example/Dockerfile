FROM ruby:3.4

WORKDIR /app

COPY caldav.gemspec Gemfile ./
COPY lib/ lib/

COPY example/Gemfile example/Gemfile
RUN cd example && bundle install --jobs 4

COPY . .

EXPOSE 9292

WORKDIR /app/example

CMD ["bundle", "exec", "falcon", "host"]
