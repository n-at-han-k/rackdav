# frozen_string_literal: true

require "bundler/setup"
require "caldav"

module Caldav
  module Contacts
    class Delete
      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        path = Path.new(request.path_info, storage_class: env['caldav.storage'])

        if request.request_method != 'DELETE' || !path.start_with?('/addressbooks/')
          @app.call(env)
        elsif !env['dav.user'].present?
          [401, { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="caldav"' }, ['Unauthorized']]
        else
          item = DavItem.find(path)

          if item
            item.delete
            [204, {}, ['']]
          elsif DavCollection.exists?(path.ensure_trailing_slash)
            DavCollection.find(path.ensure_trailing_slash).delete
            [204, {}, ['']]
          else
            [404, { 'content-type' => 'text/plain' }, ['Not Found']]
          end
        end
      end
    end
  end
end

test do
  TM = Caldav::TestMiddleware

  it "deletes a contact and returns 204" do
    mw = TM.new(Caldav::Contacts::Delete)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    mw.storage.put_item('/addressbooks/admin/addr/contact.vcf', 'data', 'text/vcard')
    env = TM.env('DELETE', '/addressbooks/admin/addr/contact.vcf')
    status, = mw.call(env)
    status.should == 204
    mw.storage.get_item('/addressbooks/admin/addr/contact.vcf').should.be.nil
  end

  it "deletes an addressbook collection and returns 204" do
    mw = TM.new(Caldav::Contacts::Delete)
    mw.storage.create_collection('/addressbooks/admin/addr/', type: :addressbook)
    env = TM.env('DELETE', '/addressbooks/admin/addr/')
    status, = mw.call(env)
    status.should == 204
    mw.storage.collection_exists?('/addressbooks/admin/addr/').should.be.false
  end

  it "returns 404 for non-existent resource" do
    mw = TM.new(Caldav::Contacts::Delete)
    env = TM.env('DELETE', '/addressbooks/admin/nope/')
    status, = mw.call(env)
    status.should == 404
  end

  it "passes through for non-addressbook path" do
    mw = TM.new(Caldav::Contacts::Delete)
    env = TM.env('DELETE', '/calendars/admin/cal/')
    status, = mw.call(env)
    status.should == 999
  end

  it "returns 401 without auth" do
    mw = TM.new(Caldav::Contacts::Delete, nil, user: nil)
    status, = mw.call(TM.env('DELETE', '/addressbooks/admin/addr/contact.vcf'))
    status.should == 401
  end
end
