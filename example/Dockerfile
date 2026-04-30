FROM ruby:3.4-slim

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the gem source first for layer caching
COPY caldav.gemspec Gemfile LICENSE ./
COPY lib/ lib/

# Copy the example Gemfile and install deps
COPY example/Gemfile example/Gemfile
RUN cd example && bundle install --jobs 4

# Copy everything else
COPY . .

EXPOSE 9292

WORKDIR /app/example

CMD ["bundle", "exec", "falcon", "serve", "--bind", "http://0.0.0.0:9292"]
