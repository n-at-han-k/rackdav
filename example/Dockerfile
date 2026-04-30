FROM ruby:3.4

WORKDIR /app

COPY Gemfile Gemfile.lock caldav.gemspec ./
COPY lib/caldav/version.rb ./lib/caldav/version.rb
RUN bundle install

COPY . .
RUN chmod +x service.rb

EXPOSE 3000
CMD ["bundle", "exec", "./service.rb"]
