# frozen_string_literal: true

require "bundler/setup"
require "caldav"

require 'uri'

module Caldav
  module Contacts
    class Move
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'MOVE' || !path.start_with?('/addressbooks/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          destination = env['HTTP_DESTINATION']

          if !destination
            [400, { 'content-type' => 'text/plain' }, ['Missing Destination header']]
          else
            to_path = Path.new(URI.parse(destination).path, storage_class: env['caldav.storage'])
            overwrite = env['HTTP_OVERWRITE'] != 'F'
            item = DavItem.find(path)

            if !item
              [404, { 'content-type' => 'text/plain' }, ['Not Found']]
            else
              existing = DavItem.find(to_path)

              if existing && !overwrite
                [412, { 'content-type' => 'text/plain' }, ['Precondition Failed']]
              else
                item.move_to(to_path)
                [existing ? 204 : 201, {}, ['']]
              end
            end
          end
        end
      end
    end
  end
end

test do
  TM = Caldav::Storage::TestMiddleware

  it "moves a contact and returns 201" do
    mw = TM.new(Caldav::Contacts::Move)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    mw.storage.put_item('/addressbooks/admin/addr/a.vcf', 'data', 'text/vcard')
    env = TM.env('MOVE', '/addressbooks/admin/addr/a.vcf',
                 headers: { 'Destination' => 'http://localhost/addressbooks/admin/addr/b.vcf' })
    status, = mw.call(env)
    status.should == 201
    mw.storage.get_item('/addressbooks/admin/addr/a.vcf').should.be.nil
    mw.storage.get_item('/addressbooks/admin/addr/b.vcf').should.not.be.nil
  end

  it "returns 404 for missing source" do
    mw = TM.new(Caldav::Contacts::Move)
    env = TM.env('MOVE', '/addressbooks/admin/addr/nope.vcf',
                 headers: { 'Destination' => 'http://localhost/addressbooks/admin/addr/b.vcf' })
    status, = mw.call(env)
    status.should == 404
  end

  it "returns 400 without Destination header" do
    mw = TM.new(Caldav::Contacts::Move)
    mw.storage.put_item('/addressbooks/admin/addr/a.vcf', 'data', 'text/vcard')
    env = TM.env('MOVE', '/addressbooks/admin/addr/a.vcf')
    status, = mw.call(env)
    status.should == 400
  end

  it "returns 412 when Overwrite is F and destination exists" do
    mw = TM.new(Caldav::Contacts::Move)
    mw.storage.put_item('/addressbooks/admin/addr/a.vcf', 'data-a', 'text/vcard')
    mw.storage.put_item('/addressbooks/admin/addr/b.vcf', 'data-b', 'text/vcard')
    env = TM.env('MOVE', '/addressbooks/admin/addr/a.vcf',
                 headers: { 'Destination' => 'http://localhost/addressbooks/admin/addr/b.vcf',
                             'Overwrite' => 'F' })
    status, = mw.call(env)
    status.should == 412
    mw.storage.get_item('/addressbooks/admin/addr/a.vcf').should.not.be.nil
    mw.storage.get_item('/addressbooks/admin/addr/b.vcf')[:body].should == 'data-b'
  end

  it "returns 204 when overwriting an existing destination" do
    mw = TM.new(Caldav::Contacts::Move)
    mw.storage.put_item('/addressbooks/admin/addr/a.vcf', 'data-a', 'text/vcard')
    mw.storage.put_item('/addressbooks/admin/addr/b.vcf', 'data-b', 'text/vcard')
    env = TM.env('MOVE', '/addressbooks/admin/addr/a.vcf',
                 headers: { 'Destination' => 'http://localhost/addressbooks/admin/addr/b.vcf' })
    status, = mw.call(env)
    status.should == 204
    mw.storage.get_item('/addressbooks/admin/addr/a.vcf').should.be.nil
    mw.storage.get_item('/addressbooks/admin/addr/b.vcf')[:body].should == 'data-a'
  end

  it "passes through for non-addressbook path" do
    mw = TM.new(Caldav::Contacts::Move)
    env = TM.env('MOVE', '/calendars/admin/cal/x.ics')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Contacts::Move, nil, user: nil)
    status, = mw.call(TM.env('MOVE', '/addressbooks/admin/addr/a.vcf',
                 headers: { 'Destination' => 'http://localhost/addressbooks/admin/addr/b.vcf' }))
    status.should == 401
  end
end
