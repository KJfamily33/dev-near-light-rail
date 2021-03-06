@echo off
setlocal EnableDelayedExpansion

::Set project workspace information
set workspace=G:\PUBLIC\GIS_Projects\Development_Around_Lightrail
set code_workspace=%workspace%\github\dev-near-lightrail
set /p data_folder="Enter the name of the subfolder will be created for this iteration of the project (should be in 'YYYY_MM' format): "
set data_workspace=%workspace%\data\%data_folder%

::Set postgres parameters
set pg_host=localhost
set db_name=osmosis_ped
set pg_user=postgres

::Prompt the user to enter their postgres password, pgpassword is a keyword and will set 
::the password for all psotgres commands in this session
set /p pgpassword="Enter postgres password: "
echo %pgpassword%

call:createPostgisDb
call:runOsmosis
::call:buildStreetsPaths
::call:export2shp

goto:eof


::---------------------------------------
:: ***Function section begins below***
::---------------------------------------

:createPostgisDb
::Create a postgis and hstore enabled postgres database (first deleting it if it exixts)

dropdb -h %pg_host% -U %pg_user% --if-exists -i %db_name%
createdb -O %pg_user% -h %pg_host% -U %pg_user% %db_name%

set q1="CREATE EXTENSION postgis;"
psql -h %pg_host% -U %pg_user% -d %db_name% -c %q1%

set q2="CREATE EXTENSION hstore;"
psql -h %pg_host% -U %pg_user% -d %db_name% -c %q2%

goto:eof


:runOsmosis
::Use osmosis to populate a postgis database with openstreetmap data

::Run the pgsnapshot_schema osmosis script on the new database to establish a schema that osmosis
::can import osm data into.  The file path below is in quotes to properly handled the spaces that
::are in the name.  This schema puts all osm tags into a single hstore column
set osmosis_pgsnapshot="C:\Program Files (x86)\Osmosis\script\pgsnapshot_schema_0.6.sql"
psql -h %pg_host% -d %db_name% -U %pg_user% -f %osmosis_pgsnapshot%

::Run osmosis on the OSM extract that is downloaded nightly using the Overpass API. The output will
::only include features that have one or more of the tags in the file keyvaluelistfile.txt. This file
::contains osm tags as key-value pairs separated by a period with one per line.  Only tags that are
::in the tagtransform.xml file will be preserved on the features that are brought through.
set osm_data=G:\PUBLIC\OpenStreetMap\data\osm\or-wa.osm
set key_value_list=%code_workspace%\osmosis\keyvaluelistfile.txt
set tag_transform=%code_workspace%\osmosis\tagtransform.xml

::Without 'call' command here this script will stop after the osmosis command
::See osmosis documentation here: http://wiki.openstreetmap.org/wiki/Osmosis/Detailed_Usage#Data_Manipulation_Tasks
::The or-wa.osm extract is being trimmed to roughly the bounding box of the trimet district
::call osmosis -v ^
::	--read-xml %osm_data% ^
::	--wkv keyValueList=highway.residential,highway.footway ^
::	--tt %tag_transform% ^
::	--bounding-box left=-123.2 right=-122.2 bottom=45.2 top=45.7 completeWays=yes ^
::	--write-pgsql host=%pg_host% database=%db_name% user=%pg_user% password=%pgpassword%

call osmosis ^
	--read-xml $osm_data -v ^
	--wkv keyValueListFile="${key_value_list}" ^
	--used-node ^
	--tt "$tag_transform" ^
	--bb left='-123.2' right='-122.2' bottom='45.2' top='45.7' ^
		completeWays=yes ^
	--write-pgsql host=$pg_host database=$pg_dbname ^
		user=$pg_user password=$PGPASSWORD 

goto:eof


:buildStreetsPaths
::Run the 'compose_paths' sql script, this will build all streets and trails from the decomposed
::osmosis osm data, the output will be inserted into a new table called 'streets_and_trails'.
::This script will also reproject the data to Oregon State Plane North (2913)
set build_paths_script=%code_workspace%\postgis\compose_paths.sql
psql -h %pg_host% -d %db_name% -U %pg_user% -f %build_paths_script%

goto:eof


:export2shp
::Export the street and trails table to a shapefile

set shapefile_out=%data_workspace%\osm_foot.shp
set table=streets_and_trails
pgsql2shp -k -h %pg_host% -u %pg_user% -P %pgpassword% -f %shapefile_out% %db_name% %table%

goto:eof