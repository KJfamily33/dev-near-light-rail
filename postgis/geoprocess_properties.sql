--Grant Humphries for TriMet, 2014
--PostGIS Version: 2.1
--PostGreSQL Version: 9.3
---------------------------------

--***Taxlots***

--------------------------
--CREATE ANALYSIS TAXLOTS
drop table if exists analysis_taxlots cascade;
create table analysis_taxlots (
	id serial primary key,
	gid int references taxlots_no_orca, 
	geom geometry,
	tlid text,
	totalval numeric,
	gis_acres numeric,
	prop_code text,
	landuse text,
	yearbuilt int,
	max_year int,
	max_zone text,
	near_max boolean,
	walk_dist numeric,
	ugb boolean,
	tm_dist boolean,
	nine_cities boolean
);

--Temp table will turn the 9 most populous cities in the TM district into a single geometry
drop table if exists nine_cities cascade;
create temp table nine_cities as
	select ST_Union(geom) as geom
	from (select city.gid, city.geom, 1 as collapser
 		from city
 		where cityname in ('Portland', 'Gresham', 'Hillsboro', 'Beaverton', 
 			'Tualatin', 'Tigard', 'Lake Oswego', 'Oregon City', 'West Linn')) as collapsable_city
	group by collapser;

--Spatially join the tax lots and isochrones (the former of which indicates areas that are within a given
--walking distance of max stops).  The output is tax lots joined to attribute information of the isochrones
--that they intersect.  Note that there are intentionally duplicates in this table if a taxlot is within
--walking distance multiple stops that are in different 'MAX Zones', but duplicates of a properties within
--the same MAX Zone are eliminated
insert into analysis_taxlots
	select tno.gid, tno.geom, tno.tlid, tno.totalval, tno.gis_acres, tno.prop_code, tno.landuse,
		tno.yearbuilt, min(iso.incpt_year), iso.max_zone, true, iso.walk_dist,
		(select ST_Intersects(geom, tno.geom) from ugb),
		(select ST_Intersects(geom, tno.geom) from tm_district),
		(select ST_Intersects(geom, tno.geom) from nine_cities)
	from taxlots_no_orca tno
		join isochrones iso
		--This command joins two features only if they intersect
		on ST_Intersects(tno.geom, iso.geom)
	group by tno.gid, tno.geom, tno.tlid, tno.totalval, tno.gis_acres, tno.prop_code, tno.landuse,
		tno.yearbuilt, iso.max_zone, iso.walk_dist;

--clean up after insert
vacuum analyze analysis_taxlots;

--Get the gid's of the taxlots that are within walking distance, put them in a table and
--index their gid's
drop table if exists max_taxlots cascade;
create temp table max_taxlots as
	select gid
	from analysis_taxlots;

drop index if exists max_tl_gid_ix cascade;
create index max_tl_gid_ix on max_taxlots using BTREE (gid);

--Find the max zone and max year of the nearest stop to each tax lot, put it in a table
--and index the gid's of those tax lots
drop table if exists nearest_stop cascade;
create temp table nearest_stop as
	select gid, geom, 
		--a subquery in the select clause can only return one value, but I need two
		--from the stops table so I'm putting them into an array
		(select array[incpt_year::text, max_zone] 
		from max_stops order by geom <-> tno.geom limit 1) as year_zone
	from taxlots_no_orca tno;

drop index if exists near_stop_gid_ix cascade;
create index near_stop_gid_ix on nearest_stop using BTREE (gid);


--Insert taxlots that are not within walking distance of max stops into analysis_taxlots 
insert into analysis_taxlots (gid, geom, tlid, totalval, gis_acres, prop_code,
		landuse, yearbuilt, max_year, max_zone, near_max)
	select tno.gid, tno.geom, tno.tlid, tno.totalval, tno.gis_acres, 
		tno.prop_code, tno.landuse, tno.yearbuilt, 
		--Finds nearest neighbor in the max stops data set for each taxlot and returns the stop's 
		--corresponding 'MAX Zone' (a zone was assigned to each stop earlier in the project),
		--derived from (http://gis.stackexchange.com/questions/52792/calculate-min-distance-between-points-in-postgis)
		ns.year_zone[0]::int, ns.year_zone[1], false
	from taxlots_no_orca tno, nearest_stop ns
	where tno.gid = ns.gid
		and tno.gid not in (select gid from max_taxlots);

--clean up after inserts
vacuum analyze analysis_taxlots;


--Add index to improve performance on upcoming spatial comparisons
drop index if exists a_taxlot_gix cascade;
create index a_taxlot_gix on analysis_taxlots using GIST (geom);

cluster analysis_taxlots using a_taxlot_gix;
vacuum analyze analysis_taxlots;

--Temp table will turn the 9 most populous cities in the TM district into a single geometry
drop table if exists nine_cities cascade;
create temp table nine_cities as
	select ST_Union(geom) as geom
	from (select city.gid, city.geom, 1 as collapser
 		from city
 		where cityname in ('Portland', 'Gresham', 'Hillsboro', 'Beaverton', 
 			'Tualatin', 'Tigard', 'Lake Oswego', 'Oregon City', 'West Linn')) as collapsable_city
	group by collapser;

--Determine if each of the analysis taxlots is in the trimet district, urban growth boundary, 
--and city limits of the nine biggest cities in the Portland metro area (Oregon only)
update analysis_taxlots as atx set
	--Returns True if a taxlot intersects the urban growth boundary
	ugb = (select ST_Intersects(ugb.geom, atx.geom)
		from ugb),
	--Returns True if a taxlot intersects the TriMet's service district boundary
	tm_dist = (select ST_Intersects(td.geom, atx.geom)
		from tm_district td),
	--Returns True if a taxlot intersects one of the nine most populous cities in the TM dist
	nine_cities = (select ST_Intersects(nc.geom, atx.geom)
		from nine_cities nc);


-----------------------------------------------------------------------------------------------------------------
--***Multi-Family Housing Units***
--Works off the same framework as what is used for tax lots above.  Note that the natural areas
--don't need to be used as a filter in the way that they were with tax lots as we already know
--the type of property each of these are

--------------------------
--CREATE ANALYSIS MULTIFAM
--Divisors for overall area comparisons will still come from analysis_taxlots, but numerators
--will come from the table below.  This because the multi-family layer doesn't have full coverage
--of all buildable land in the region the way the tax lot data does
drop table if exists analysis_multifam cascade;
create table analysis_multifam (
	id serial primary key,
	gid int references multifamily, 
	geom geometry,
	metro_id int,
	units int,
	unit_type text,
	gis_acres numeric,
	mixed_use int,
	yearbuilt int,
	max_year int,
	max_zone text,
	near_max boolean,
	walk_dist numeric,
	ugb boolean,
	tm_dist boolean,
	nine_cities boolean
);

insert into analysis_multifam (gid, geom, metro_id, units, unit_type, gis_acres, mixed_use, 
		yearbuilt, max_year, max_zone, near_max, walk_dist)
	select tm.gid, tm.geom, tm.metro_id, tm.units, tm.unit_type, tm.gis_acres, tm.mixed_use,
		tm.yearbuilt, min(iso.incpt_year), iso.max_zone, true, iso.walk_dist
	from multifamily tm
		join isochrones iso
		on ST_Intersects(tm.geom, iso.geom)
	group by tm.gid, tm.geom, tm.metro_id, tm.units, tm.yearbuilt, tm.unit_type, tm.gis_acres, 
		tm.mixed_use, iso.max_zone, iso.walk_dist;

vacuum analyze analysis_multifam;

cluster multifamily using multifamily_geom_gist;
analyze multifamily;

--Insert multifam units outside of walking distance into the analysis-multifam
insert into analysis_multifam (gid, geom, metro_id, units, unit_type, gis_acres,
		mixed_use, yearbuilt, max_zone, near_max)
	select tm.gid, tm.geom, tm.metro_id, tm.units, tm.unit_type, tm.gis_acres,
		tm.mixed_use, tm.yearbuilt,
		--get max zone for nearest stop using nearest neighbor
		(select mxs.max_zone
			from max_stops mxs 
			order by mxs.geom <-> tm.geom
			limit 1), false
	from multifamily tm
	where tm.gid not in (select gid from analysis_multifam);

vacuum analyze analysis_multifam;

--Populate max_year column for properties outside max stop walking distance based on
--max_year_zone_mapping table
update analysis_multifam amf set max_year = yzm.max_year
	from max_year_zone_mapping yzm
	where yzm.max_zone = amf.max_zone
		and amf.near_max is false;

--Should improve performance on upcoming spatial comparisons
drop index if exists a_multifam_gix cascade;
create index a_multifam_gix on analysis_multifam using GIST (geom);

cluster analysis_multifam using a_multifam_gix;
vacuum analyze analysis_multifam;

update analysis_multifam as amf set
	ugb = (select ST_Intersects(ugb.geom, amf.geom)
		from ugb),

	tm_dist = (select ST_Intersects(td.geom, amf.geom)
		from tm_district td),

	nine_cities = (select ST_Intersects(nc.geom, amf.geom)
		from nine_cities nc);

--Temp table is no longer needed
drop table max_year_zone_mapping cascade;
drop table nine_cities cascade;

--ran in ~4,702,524 ms on 5/20/14 (definitely benefitted from some caching though)