##
## Download data from figshare
## https://figshare.com/articles/NZ_vehicles_database/5971471
##
### Code for MonetDB

library(dbglm)
library(DBI)
library(MonetDBLite)
library(dplyr)
library(dbplyr)
library(purrr)
library(tidyr) # Eventually just library(tidyverse)
library(rlang)
library(tibble)
library(vctrs)
library(tidypredict)

ms <- MonetDBLite::src_monetdblite("~/VEHICLE")
monetdb.read.csv(ms$con, "Fleet30Nov2017.csv",tablename="vehicles",quote="",nrow.check=10000,best.effort=TRUE,lower.case.names=TRUE)
vehicles<-tbl(ms,"vehicles")
cars <- filter(vehicles, vehicle_type == "PASSENGER CAR/VAN") %>% 
  mutate(isred=ifelse(basic_colour=="RED",1,0)) %>% 
  filter(number_of_seats >1 & number_of_seats < 7) %>% filter(number_of_axles==2) %>%
  compute()

system.time({
  model<-dbglm(isred~power_rating+number_of_seats+gross_vehicle_mass,tbl=cars)
})

### Code for SQLite
library(dbglm)
library(RSQLite)
library(dplyr)
library(dbplyr)


# data setup

vehicles<-readr::read_csv("Fleet30Nov2017.csv") # TODO: read_csv_rsqlite() ???
names(vehicles)<-tolower(names(vehicles))
vehicles$power_rating<-as.numeric(as.character(vehicles$power_rating))
vehicles$number_of_seats<-as.numeric(as.character(vehicles$number_of_seats))
vehicles$number_of_axles<-as.numeric(as.character(vehicles$number_of_axles))

sqlite<-dbDriver("SQLite")
con<-dbConnect(sqlite,"nzcars.db")
RSQLite:::initExtension(con)
dbWriteTable(con,"vehicles",vehicles)
rm(vehicles)
dbDisconnect(con)

# analysis
library(dbglm)
library(RSQLite)
library(dplyr)
library(dbplyr)

sqlite<-dbDriver("SQLite")
con<-dbConnect(sqlite,"nzcars.db")
RSQLite:::initExtension(con)
sqlitevehicles<-tbl(con,"vehicles")


cars <- filter(sqlitevehicles, vehicle_type == "PASSENGER CAR/VAN") %>%
  mutate(isred=ifelse(basic_colour=="RED",1,0)) %>% 
  filter(number_of_seats >1 & number_of_seats < 7) %>% filter(number_of_axles==2) %>%
  compute()

system.time({
  sqlitemodel<-dbglm(isred~power_rating+number_of_seats+gross_vehicle_mass,tbl=cars)
})

sqrt(diag(sqlitemodel$hatV)*2917)


# Data Setup for duckDB
library(duckdb)
con_duck<- dbConnect(duckdb::duckdb(), "duck") 
vehicles<- read.csv("Fleet30Nov2017.csv") # TODO: duckdb::read_csv_duckdb()
names(vehicles)<-tolower(names(vehicles))
vehicles$power_rating<-as.numeric(as.character(vehicles$power_rating))
vehicles$number_of_seats<-as.numeric(as.character(vehicles$number_of_seats))
vehicles$number_of_axles<-as.numeric(as.character(vehicles$number_of_axles))
dbWriteTable(con_duck, "cars", vehicles, overwrite = T)
cars<- tbl(con_duck, "cars")
cars1 <- filter(cars, vehicle_type == "PASSENGER CAR/VAN") %>% 
  mutate(isred=ifelse(basic_colour=="RED",1,0)) %>% 
  filter(number_of_seats >1 & number_of_seats < 7) %>% filter(number_of_axles==2) %>%
  compute()
model<-dbglm(isred~power_rating+number_of_seats+gross_vehicle_mass,tbl=cars1)
