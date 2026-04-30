# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Contacts
    class Put
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'PUT' || !path.start_with?('/addressbooks/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          body = request.body.read

          if body.nil? || body.strip.empty?
            [400, { 'content-type' => 'text/plain' }, ['Empty body']]
          elsif !body.strip.start_with?('BEGIN:VCARD')
            [400, { 'content-type' => 'text/plain' }, ['Invalid vCard data']]
          else
            existing = DavItem.find(path)
            if_match = env['HTTP_IF_MATCH']
            if_none_match = env['HTTP_IF_NONE_MATCH']

            if if_match && (!existing || existing.etag != if_match)
              return [412, { 'content-type' => 'text/plain' }, ['If-Match precondition failed']]
            end

            if if_none_match == '*' && existing
              return [412, { 'content-type' => 'text/plain' }, ['If-None-Match precondition failed']]
            end

            # Check for duplicate UID in the collection
            uid_match = body.match(/^UID:(.+)$/i)
            if uid_match && !existing
              uid = uid_match[1].strip
              collection_path = path.parent.to_s
              storage = env['caldav.storage']
              if storage.respond_to?(:list_items)
                storage.list_items(collection_path).each do |item_path, item_data|
                  next if item_path == path.to_s
                  if item_data[:body].match?(/^UID:#{Regexp.escape(uid)}$/i)
                    return [409, { 'content-type' => 'text/xml; charset=utf-8' }, ['UID conflict']]
                  end
                end
              end
            end

            content_type = request.content_type || 'text/vcard'
            item = DavItem.create(path, body: body, content_type: content_type)

            [item.new? ? 201 : 204, { 'etag' => item.etag, 'content-type' => 'text/plain' }, ['']]
          end
        end
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  it "creates a new vcard and returns 201 with etag" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    env = TM.env('PUT', '/addressbooks/admin/addr/contact.vcf',
                 body: 'BEGIN:VCARD\nEND:VCARD', content_type: 'text/vcard; charset=utf-8')
    status, headers, = mw.call(env)
    status.should == 201
    headers['etag'].should.not.be.nil
  end

  it "rejects empty body with 400" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    env = TM.env('PUT', '/addressbooks/admin/addr/contact.vcf')
    status, = mw.call(env)
    status.should == 400
  end

  it "updates an existing contact and returns 204" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    mw.storage.put_item('/addressbooks/admin/addr/contact.vcf', 'BEGIN:VCARD\nVERSION:1\nEND:VCARD', 'text/vcard')
    env = TM.env('PUT', '/addressbooks/admin/addr/contact.vcf',
                 body: 'BEGIN:VCARD\nVERSION:2\nEND:VCARD', content_type: 'text/vcard')
    status, headers, = mw.call(env)
    status.should == 204
    headers['etag'].should.not.be.nil
  end

  # --- Body validation tests ---

  it "rejects body that does not start with BEGIN:VCARD" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    env = TM.env('PUT', '/addressbooks/admin/addr/c.vcf', body: 'NOT A VCARD', content_type: 'text/vcard')
    status, = mw.call(env)
    status.should == 400
  end

  it "accepts body starting with BEGIN:VCARD" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    env = TM.env('PUT', '/addressbooks/admin/addr/c.vcf', body: "BEGIN:VCARD\r\nEND:VCARD", content_type: 'text/vcard')
    status, = mw.call(env)
    status.should == 201
  end

  # --- ETag precondition tests ---

  it "returns 412 when If-Match does not match existing etag" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    old = "BEGIN:VCARD\nVERSION:3.0\nFN:Old\nEND:VCARD"
    mw.storage.put_item('/addressbooks/admin/addr/c.vcf', old, 'text/vcard')
    env = TM.env('PUT', '/addressbooks/admin/addr/c.vcf', body: "BEGIN:VCARD\nFN:New\nEND:VCARD", content_type: 'text/vcard',
                 headers: { 'If-Match' => '"wrong"' })
    status, = mw.call(env)
    status.should == 412
    mw.storage.get_item('/addressbooks/admin/addr/c.vcf')[:body].should == old
  end

  it "returns 204 when If-Match matches existing etag" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    old = "BEGIN:VCARD\nVERSION:3.0\nFN:Old\nEND:VCARD"
    mw.storage.put_item('/addressbooks/admin/addr/c.vcf', old, 'text/vcard')
    real_etag = mw.storage.get_item('/addressbooks/admin/addr/c.vcf')[:etag]
    env = TM.env('PUT', '/addressbooks/admin/addr/c.vcf', body: "BEGIN:VCARD\nFN:New\nEND:VCARD", content_type: 'text/vcard',
                 headers: { 'If-Match' => real_etag })
    status, = mw.call(env)
    status.should == 204
  end

  it "returns 412 when If-Match set but contact does not exist" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    env = TM.env('PUT', '/addressbooks/admin/addr/new.vcf', body: "BEGIN:VCARD\nFN:X\nEND:VCARD", content_type: 'text/vcard',
                 headers: { 'If-Match' => '"some-etag"' })
    status, = mw.call(env)
    status.should == 412
  end

  it "returns 412 when If-None-Match is * and contact exists" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    old = "BEGIN:VCARD\nFN:Old\nEND:VCARD"
    mw.storage.put_item('/addressbooks/admin/addr/c.vcf', old, 'text/vcard')
    env = TM.env('PUT', '/addressbooks/admin/addr/c.vcf', body: "BEGIN:VCARD\nFN:New\nEND:VCARD", content_type: 'text/vcard',
                 headers: { 'If-None-Match' => '*' })
    status, = mw.call(env)
    status.should == 412
    mw.storage.get_item('/addressbooks/admin/addr/c.vcf')[:body].should == old
  end

  it "returns 201 when If-None-Match is * and contact does not exist" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    env = TM.env('PUT', '/addressbooks/admin/addr/new.vcf', body: "BEGIN:VCARD\nFN:X\nEND:VCARD", content_type: 'text/vcard',
                 headers: { 'If-None-Match' => '*' })
    status, = mw.call(env)
    status.should == 201
  end

  it "passes through for non-addressbook path" do
    mw = TM.new(Caldav::Contacts::Put)
    env = TM.env('PUT', '/calendars/admin/cal/event.ics', body: 'data')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Contacts::Put, nil, user: nil)
    status, = mw.call(TM.env('PUT', '/addressbooks/admin/addr/contact.vcf', body: 'data'))
    status.should == 401
  end

  # --- Duplicate UID tests ---

  it "rejects PUT with duplicate UID in same addressbook" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    c1 = "BEGIN:VCARD\nUID:dup-uid\nFN:First\nEND:VCARD"
    c2 = "BEGIN:VCARD\nUID:dup-uid\nFN:Second\nEND:VCARD"
    mw.storage.put_item('/addressbooks/admin/addr/c1.vcf', c1, 'text/vcard')
    env = TM.env('PUT', '/addressbooks/admin/addr/c2.vcf', body: c2, content_type: 'text/vcard')
    status, = mw.call(env)
    status.should == 409
  end

  it "allows PUT with same UID to same path (update)" do
    mw = TM.new(Caldav::Contacts::Put)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    c1 = "BEGIN:VCARD\nUID:uid-1\nFN:First\nEND:VCARD"
    c2 = "BEGIN:VCARD\nUID:uid-1\nFN:Updated\nEND:VCARD"
    mw.storage.put_item('/addressbooks/admin/addr/c.vcf', c1, 'text/vcard')
    env = TM.env('PUT', '/addressbooks/admin/addr/c.vcf', body: c2, content_type: 'text/vcard')
    status, = mw.call(env)
    status.should == 204
  end
end
