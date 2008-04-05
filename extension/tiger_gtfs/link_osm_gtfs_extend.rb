class Graphserver
  SEARCH_RANGE = 0.0006 #degrees

  def each_stop
    stops = conn.exec "SELECT stop_id, location FROM gtf_stops"
    stops.each do |stop_id, location|
      yield stop_id, location
    end
  end

  def nearest_osm_line( stop_geom, search_range )
     lines = conn.exec <<-SQL
       SELECT id, geom, distance(geom, '#{stop_geom}') AS dist 
       FROM osm_streets
       WHERE geom && expand( '#{stop_geom}'::geometry, #{search_range} )
       ORDER BY dist 
       LIMIT 1
     SQL
     
     if lines.num_tuples == 0 then
       return nil, nil
     else
       return lines[0][0..1]
     end
  end

  def split_osm_line line_geom, stop_geom
    ret = []

    split = conn.exec("SELECT line_locate_point('#{line_geom}', '#{stop_geom}')").getvalue(0, 0).to_f
    
    #no need to split the line if the splitpoint is at the end
    if split == 0 or split == 1 then
      return nil
    end

    ret << conn.exec("SELECT line_substring('#{line_geom}', 0, #{split})").getvalue(0,0)
    ret << conn.exec("SELECT line_substring('#{line_geom}', #{split}, 1)").getvalue(0,0)
    
    return ret;
  end

  #tlid : line_id of the record to replace
  #tlid_l : line_id of the left line
  #tlid_r : line_id of the right line
  #tzid : endpoint-id joining the new split line
  #left : WKB of the lefthand line
  #right : WKB of he righthand line
  def split_osm_line! tlid, tlid_l, tlid_r, tzid, left, right
    res = conn.exec("SELECT * FROM osm_streets WHERE id = #{tlid}")
    nid = res.fieldnum( 'id' )
    nto_id = res.fieldnum( 'to_id' )
    nfrom_id = res.fieldnum( 'from_id' )
    ngeom = res.fieldnum( 'geom' )
    row = res[0]

    leftrow = row.dup
    rightrow = row.dup

    leftrow[ nid ] = tlid_l
    leftrow[ nto_id] = tzid
    leftrow[ ngeom ] = left
    rightrow[ nid ] = tlid_r
    rightrow[ nfrom_id ] = tzid
    rightrow[ ngeom ] = right

    transaction = ["BEGIN;"]
    transaction << "DELETE FROM osm_streets WHERE id = #{tlid};"
    transaction << "INSERT INTO osm_streets (#{res.fields.join(',')}) VALUES (#{leftrow.map do |x| if x then "'"+x+"'" else '' end end.join(",")});"
    transaction << "INSERT INTO osm_streets (#{res.fields.join(',')}) VALUES (#{rightrow.map do |x| if x then "'"+x+"'" else '' end end.join(",")});"
    transaction << "COMMIT;"

    p transaction.join
 
    conn.exec( transaction.join )
  end

  def split_osm_lines!
    each_stop do |stop_id, stop_geom|
      line_id, line_geom = nearest_osm_line( stop_geom, SEARCH_RANGE )
      if line_id then
        left, right = split_osm_line( line_geom, stop_geom )
        if left then
          split_osm_line!( line_id, stop_id+"0", stop_id+"1", stop_id, left, right )
        end
      end
    end
  end

  def nearest_street_node stop_geom
    point, dist = conn.exec(<<-SQL)[0]
      SELECT from_id AS point, 
             distance_sphere(StartPoint(geom), '#{stop_geom}') AS dist
      FROM osm_streets
      WHERE geom && expand( '#{stop_geom}'::geometry, #{SEARCH_RANGE} )
      UNION 
        (SELECT to_id AS point, 
                distance_sphere(EndPoint(geom), '#{stop_geom}') AS dist
         FROM osm_streets
         WHERE geom && expand( '#{stop_geom}'::geometry, #{SEARCH_RANGE}))
      ORDER BY dist LIMIT 1
    SQL

    return point
  end

  def remove_link_table!
    begin
      conn.exec "DROP TABLE street_gtfs_links"
    rescue
      nil
    end
  end

  def create_link_table!
    #an extremely simple join table
    conn.exec <<-SQL
      create table street_gtfs_links (
        stop_id            text NOT NULL,
        node_id            text NOT NULL
      );
    SQL
  end

  def link_street_gtfs!
    each_stop do |stop_id, stop_geom|
      if node_id = nearest_street_node( stop_geom ) then
        p node_id
        conn.exec "INSERT INTO street_gtfs_links (stop_id, node_id) VALUES (#{stop_id}, #{node_id})"
      end
    end
  end

  def load_osm_gtfs_links
    res = conn.exec "SELECT stop_id, node_id FROM street_gtfs_links"

    res.each do |stop_id, node_id|
      @gg.add_edge( GTFS_PREFIX+stop_id, TIGER_PREFIX+node_id, Link.new )
      @gg.add_edge( TIGER_PREFIX+node_id, GTFS_PREFIX+stop_id, Link.new )
    end
  end
end