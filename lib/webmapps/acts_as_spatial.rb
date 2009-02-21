module Webmapps 
  module ActsAsSpatial 
    def self.included(base) 
      base.extend ActMethods 
    end 
    module ActMethods
      attr_accessor :geom_column
      def acts_as_spatial(options = {})
        # if the geom_column is passed in
        # then set the geom_column. Otherwise
        # default to "the_geom"
        if options.include? (:geom)
          self.geom_column = options[:geom]
        else
         self.geom_column = "the_geom"
        end
        unless included_modules.include? InstanceMethods 
          extend ClassMethods 
          include InstanceMethods 
        end
      end 
    end 
    module ClassMethods
      attr_accessor :sql_where
      def find(*args)
        # create an array where the spatial query conditions
        # will be stored
        @sql_where = Array.new
        prepare_for_find(args)
        # if the client passed in spatial query options,
        # then limit the scope of further queries to results
        # that match the spatial query
        unless @sql_where.blank?
          with_scope(:find => { :conditions => @sql_where.join(" AND ") } ) do
            super(*args)
          end
        # if no spatial query options were specified, then
        # perform a normal find
        else
          super(*args)
        end
      end
      
      def prepare_for_find(args)
        options = defined?(args.extract_options!) ? args.extract_options! : extract_options_from_args!(args)
        # extract methods determine if the given query method
        # and passes of the conditions to prepare_sql()
        extract_intersect_from_options(options)
        extract_overlap_from_options(options)
        extract_contain_from_options(options)
        extract_touch_from_options(options)
        extract_within_from_options(options)
        args.push(options)
      end
      
      # ST_* methods are defined in the PostGIS adapter
      def extract_intersect_from_options(options)
        prepare_sql("ST_Intersects", options[:intersect])
        options.delete(:intersect)
      end
      
      def extract_overlap_from_options(options)
        prepare_sql("ST_Overlaps", options[:overlap])
        options.delete(:overlap)
      end
      
      def extract_contain_from_options(options)
        prepare_sql("ST_Contains", options[:contain])
        options.delete(:contain)
      end
      
      def extract_touch_from_options(options)
        prepare_sql("ST_Touches", options[:touch])
        options.delete(:touch)
      end
      
      def extract_within_from_options(options)
        prepare_sql("ST_Within", options[:within])
        options.delete(:within)
      end
      
      # appends to the @sql_where array a 
      # condition of the query
      def prepare_sql(st_method, geometry)
        @sql_where << ("#{st_method}(#{self.geom_column}, '#{geometry}')") unless geometry.blank?
      end
       
    end 
    module InstanceMethods 
    end 
  end
end 
