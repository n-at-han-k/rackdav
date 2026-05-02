# frozen_string_literal: true

module Protocol
  module Caldav
    class Storage
      # --- Collections ---

      def create_collection(path, props = {})
        raise NotImplementedError
      end

      def get_collection(path)
        raise NotImplementedError
      end

      def delete_collection(path)
        raise NotImplementedError
      end

      def list_collections(parent_path)
        raise NotImplementedError
      end

      def update_collection(path, props)
        raise NotImplementedError
      end

      def collection_exists?(path)
        raise NotImplementedError
      end

      # --- Items ---

      def get_item(path)
        raise NotImplementedError
      end

      def put_item(path, body, content_type)
        raise NotImplementedError
      end

      def delete_item(path)
        raise NotImplementedError
      end

      def list_items(collection_path)
        raise NotImplementedError
      end

      def move_item(from_path, to_path)
        raise NotImplementedError
      end

      def get_multi(paths)
        raise NotImplementedError
      end

      # --- General ---

      def exists?(path)
        raise NotImplementedError
      end

      def etag(path)
        raise NotImplementedError
      end
    end
  end
end
