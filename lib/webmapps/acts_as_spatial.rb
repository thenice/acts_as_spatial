# TODO: all acts_as_spatial configurations will live in lib/webmapps/config.yml 
# in the meantime...
DEFAULT_GEOM_COLUMN_NAME  =   "the_geom"
DEFAULT_AUTO_GEOCODE      =   false

module Webmapps 
  module ActsAsSpatial 
    def self.included(base) 
      base.extend ActMethods 
    end 
    module ActMethods
      attr_accessor :geom_column, :geocodable_columns, :geocoder, :geometry_type
      def acts_as_spatial(options = {})
        unless included_modules.include? InstanceMethods 
          extend ClassMethods 
          include InstanceMethods 
        end
        initialize_acts_as_spatial  # initialize plugin
        extract_options(options)    # extract parameters
      end
      
      def initialize_acts_as_spatial
        # generic application configuration here
        self.geom_column = DEFAULT_GEOM_COLUMN_NAME
      end
      
      # detect each parameter passed into acts_as_spatial
      # and route each option to specific configuration method
      def extract_options(options)
        extract_geom options[:geom] if options.include? :geom
        extract_auto_geocode options[:auto_geocode] if options.include? :auto_geocode
      end
      
      # Extract Methods
      # -----------------------------------------------------
      # these methods configure plugin prefrences based on
      # the passed in option hash. these methods will be
      # activated by the extract_options method above.
      
      # sets the name of the column storing the geometric
      # information
      def extract_geom(column_name)
        self.geom_column  = column_name
      end
      
      # evalues whether client passes in true/false
      # and starts the initialization process if true
      def extract_auto_geocode(auto_geocode)
        initialize_auto_geocoding if auto_geocode
        attach_auto_geocoding if auto_geocode
      end
      
      def extract_attach_geocoder(attach_geocoder)
        initialize_auto_geocoding if attach_geocoder
      end
      
      # creates a geocoder object, sets the acceptable
      # combinations of location columns to try and descern 
      # a point for that location, and then attaches the instance
      # method attach_auto_geocoding() to the before_save callback.
      def initialize_geocoding # move this method to seperate module
        require 'rubygems'
        require 'Graticule' # Graticule gem
        self.geocoder = Graticule.service(:google).new "api_key"
      end
        
      def attach_auto_geocoding
        self.before_save :auto_geocode
      end
      
    end 
    module ClassMethods
      attr_accessor :sql_where
      # extend the find method to permit spatial querying
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
        extract_intersects_from_options(options)
        extract_overlaps_from_options(options)
        extract_contains_from_options(options)
        extract_touches_from_options(options)
        extract_within_from_options(options)
        args.push(options)
      end
      
      # ST_* methods are defined in the PostGIS adapter
      def extract_intersects_from_options(options)
        prepare_sql("ST_Intersects", to_wkt(options[:intersects]))
        options.delete(:intersects)
      end
      
      def extract_overlaps_from_options(options)
        prepare_sql("ST_Overlaps", to_wkt(options[:overlaps]))
        options.delete(:overlaps)
      end
      
      def extract_contains_from_options(options)
        prepare_sql("ST_Contains", to_wkt(options[:contains]))
        options.delete(:contains)
      end
      
      def extract_touches_from_options(options)
        prepare_sql("ST_Touches", to_wkt(options[:touches]))
        options.delete(:touches)
      end
      
      def extract_within_from_options(options)
        prepare_sql("ST_Within", to_wkt(options[:within]))
        options.delete(:within)
      end
      
      def buffer(meters)
        begin
          if (self.get_geometry_type == "Point")
            wkt = ActiveRecord::Base.connection.execute("select astext(transform(buffer(geomunion(transform(geomfromtext(astext(the_geom), 4326), 26915)), #{meters}),4326)) FROM \"#{self.table_name}\"")[0][0]
            geom = Polygon.from_ewkt(wkt)
          elsif (self.get_geometry_type == "MultiPolygon")
            wkt = ActiveRecord::Base.connection.execute("select astext(transform(buffer(transform(geomunion(geomfromtext(astext(#{self.geom_column}),4326)),26915),#{meters}),4326)) FROM \"#{self.table_name}\"")[0][0]
            geom = Polygon.from_ewkt(wkt)
          end    
        rescue
          puts "there was a buffer error. throw an exception or something."
          nil
        end
      end
      
      
      # appends to the @sql_where array a 
      # condition of the query
      def prepare_sql(st_method, geometry)
        @sql_where << ("#{st_method}(#{self.geom_column}, '#{geometry}')") unless geometry.blank?
      end
      
      def acts_as_spatial?
        true
      end
      
      # returns a string of all features in the layer
      # represented as a GEOMETRYCOLLECTION WKT represetnation
      def to_geometry_collection
        'GEOMETRYCOLLECTION(' + (self.find(:all, :select => self.geom_column).collect { |item| item.send(self.geom_column).as_wkt }).join(',') + ')'
      end
      
      # returns a MULTI-type geometry object in WKT with all shapes in the entire table.
      # warning: geometry type is returned by whatever GeoRuby returns as the geom type.
      # warning #2: assumes that every table stores the same types of geometries. the type
      # is determined by examining the first row's geometry type.
      
      # MULTIPOLYGON(POLYGON((..,..,..,)),POLYGON((..,..,..)))
      def collect_all_shapes
        get_geometry_type.upcase + get_all_for_multi_geometry
      end 
      
      # this is ugly. 
      def get_geometry_type
        if self.geometry_type.blank?
          unless self.count == 0
            self.geometry_type = (self.find(:first)).geometry_type
          end
        else
          self.geometry_type
        end
      end
      
      # aggregates the entire table's geometries in WKT format
      def get_all_for_multi_geometry
        self.find(:all).collect { |item|
          geometry = item.end(self.geom_column)[0].as_wkt
          geometry = geometry.gsub(singular_geometry_type.upcase, "")
          "( #{geometry} )"
        }.join(",")
      end
      
      # if the geometry for this object is a MultiPolygon, this will return "Polygon"
      def singular_geometry_type
        (self.get_geometry_type).gsub(/Multi/, '')
      end
        
      # takes either a string, object that implements acts_as_spatial,
       # or a GeoRuby Point, Polygon, MultiPolygon, or Line and returns
       # the wkt representation.
       def to_wkt(value)
         unless value.blank?
           # if value is already passed in as wkt, return it.
           if value.is_a? String
             return value
           elsif (value.extended_by).include? "GeoRuby::SimpleFeatures"
             return value.send("as_wkt")
           elsif value.respond_to?("acts_as_spatial?")
             v = value.send(value.class.geom_column)
             return v.send("as_wkt")
           end
         else
           nil
         end
       end
       
       # looks for pairs of "longitude" and "latitude" or "x" and "y" and then creates
       # a geom for the pair for ALL FEATURES IN THIS LAYER
       def discover_georeference
         if not (matched = self.derive_fields(['longitude', 'latitude'])).blank?
           self.geom_from_x_y(matched[0],matched[1])
         elsif not (matched = self.derive_fields(['x','y'])).blank?
           self.geom_from_x_y(matched[0],matched[1])
         elsif ( matched = self.derive_fields(['street_address', 'city', 'state']) )
           geom_from_geocodable_columns matched
         elsif (matched = self.derive_fields(['address', 'province', 'city', 'country']))
           geom_from_geocodable_columns matched
         elsif (matched = self.derive_fields(['street_address', 'city', 'country']))
           geom_from_geocodable_columns matched
         elsif (matched = self.derive_fields(['street_address', 'oblast', 'city', 'country']))
           geom_from_geocodable_columns matched
         elsif (matched = self.derive_fields(['city', 'country']))
           geom_from_geocodable_columns matched
         elsif (matched = self.derive_fields(['address']))
           geom_from_geocodable_columns matched
         elsif (matched = self.derive_fields(['zip']))
           geom_from_geocodable_columns matched
         elsif (matched = self.derive_fields(['zipcode']))
           geom_from_geocodable_columns matched
         elsif (matched = self.derive_fields(['postal code']))
           geom_from_geocodable_columns matched
         elsif (matched = self.derive_fields(['city', 'state']))
           geom_from_geocodable_columns matched
         elsif (matched = self.derive_fields(['country']))
           geom_from_geocodable_columns matched
        end
       end
       
       def discover_geocodable_columns
       end
       
       # take two column names which store the longitude and latitude of a point
       # and creates and stores a geometry object for all features in a layer
       def geom_from_x_y(x_column_name,y_column_name) 
         self.all.each do |feature|
           begin
             feature.the_geom = Point.from_x_y(feature[x_column_name].to_f,feature[y_column_name].to_f)
             feature.save!
           rescue
             puts "Couldn't create a geom for feature with id #{feature.id}."
           end
         end
       end
       
       def geom_from_geocodable_columns(columns)
         require 'rubygems'
         require 'Graticule' # Graticule gem
         geocoder = Graticule.service(:google).new "api_key"
         self.all.each do |feature|
            begin
              geocodable_string = (feature.values_for(columns)).join(" ")
              location = geocoder.locate(geocodable_string)
              feature.the_geom = Point.from_x_y(location.longitude, location.latitude)
              feature.save!
            rescue
              puts "Couldn't create a geom for feature with id #{feature.id}."
            end
          end
       end
       
       
       # takes an array of column titles and another arrary of items to match
       # returns an array of columns that matched the items to match considering the case
       # of the arr_of_cols. returns nil if all of the items to match weren't in the cols.
       def derive_fields(items_to_match)
         num_items = items_to_match.size
         matched_items = []
         fields.each do |col|
           items_to_match.each do |match|
             matched_items << col if col.downcase == match.downcase
           end
         end
         if num_items == matched_items.size
           return matched_items.reverse
         else
           return nil
         end 
       end
       
       def fields
         self.first.attributes.collect { |k,v| k }.delete_if { |d| d == 'id' or d == 'the_geom' }
       end
       
    end 
    
    module InstanceMethods      
        def auto_geocode
          # if the geom column is empty before a save
          if (send(self.class.geom_column)).blank?
            location_text = geocodable_string
            unless location_text.blank?
              begin
                location = self.class.geocoder.locate(location_text)
                geom = Point.from_x_y(location.latitude, location.longitude)
                send("#{self.class.geom_column}=", geom)
              rescue
                # if an error occurs in the geocoding process
                # <more stuff here>
                puts "There was an error geocoding that address."
              end
            else
              puts "Location empty for this object. Can't geocode."
            end
          end
        end
                
        def values_for(selected_columns = [])
          values = Array.new
          # if all of the selected columns exist in this object's
          # column names
          if self.class.column_names.to_set.superset? (selected_columns.to_set)
            selected_columns.each do |column_name|
              # get the value, and add it to an array
              value = self.send(column_name)
              values << value
            end
          end
          values
        end
         
        # finds the first 
        def geocodable_string
          gc = ""
          self.class.geocodable_columns.each do |values|
            gc = (values_for values).join(" ")
            break
          end
          gc
        end
        
        # returns the class name of the GeoRuby object
        # being returned from the database
        def geometry_type
          unless send(self.class.geom_column).blank?
            send(self.class.geom_column).class.name.split('::').last
          end
        end
        
        # used to dynamically determine if an object
        # implements acts_as_spatial
        def acts_as_spatial?
          true
        end    
        
        def geometry
          self.send(self.class.geom_column)
        end 
        
        def google_shape
          case self.geometry_type.downcase
            when 'multipolygon'
              then GPolygon.from_georuby(self.send(self.class.geom_column)[0],'#000fff',2,10.0,random_color,0.3)
            when 'multilinestring'
               then GPolygon.from_georuby(self.send(self.class.geom_column)[0],random_color,2.5,10.0,random_color,0.3)
            when ('multipoint')
              then GMarker.from_georuby(self.send(self.class.geom_column)[0])
            when ('point')
              then GMarker.from_georuby(self.send(self.class.geom_column))
          end
        end
        
        
        private 
        
        # takes text in the "well-known-text (WKT)" format: POLYGON((3 4, 4 5, 6 1, 2 7))
        # and returns the POLYGON part.
        def geometry_type_from_text(geometry_as_text)
          # TODO: minimal testing here. match with REGEX
          if geometry_as_text.include? '('
            (geometry_as_text.split('(')).first
          end
        end
        
        def random_color
          case ((rand * 9.to_i).to_i)
            when 0 then '#6699FF'
            when 1 then  '#000080'
            when 2 then '#ff8900'
            when 3 then '#66FF33'
            when 4 then '#996633'
            when 5 then '#008080'
            when 6 then '#9999cc'
            when 7 then '#bbbbbb'
            when 8 then '#CCFF66'
          end
        end
         
    end 
  end
end