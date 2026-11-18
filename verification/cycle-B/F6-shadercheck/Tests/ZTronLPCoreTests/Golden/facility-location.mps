NAME          FACILITY
ROWS
 N COST
 L supply[0]
 L supply[1]
 L supply[2]
 G demand[0]
 G demand[1]
 G demand[2]
 G demand[3]
COLUMNS
    MARKER1 'MARKER' 'INTORG'
    open[Plant[id_0]] COST 100.0
    open[Plant[id_0]] supply[0] -60.0
    MARKER2 'MARKER' 'INTEND'
    ship[Plant[id_0],Market[id_0]] COST 1.5
    ship[Plant[id_0],Market[id_0]] supply[0] 1.0
    ship[Plant[id_0],Market[id_0]] demand[0] 1.0
    ship[Plant[id_0],Market[id_1]] COST 1.75
    ship[Plant[id_0],Market[id_1]] supply[0] 1.0
    ship[Plant[id_0],Market[id_1]] demand[1] 1.0
    ship[Plant[id_0],Market[id_2]] COST 2.0
    ship[Plant[id_0],Market[id_2]] supply[0] 1.0
    ship[Plant[id_0],Market[id_2]] demand[2] 1.0
    ship[Plant[id_0],Market[id_3]] COST 2.25
    ship[Plant[id_0],Market[id_3]] supply[0] 1.0
    ship[Plant[id_0],Market[id_3]] demand[3] 1.0
    MARKER3 'MARKER' 'INTORG'
    open[Plant[id_1]] COST 125.0
    open[Plant[id_1]] supply[1] -55.0
    MARKER4 'MARKER' 'INTEND'
    ship[Plant[id_1],Market[id_0]] COST 2.5
    ship[Plant[id_1],Market[id_0]] supply[1] 1.0
    ship[Plant[id_1],Market[id_0]] demand[0] 1.0
    ship[Plant[id_1],Market[id_1]] COST 3.0
    ship[Plant[id_1],Market[id_1]] supply[1] 1.0
    ship[Plant[id_1],Market[id_1]] demand[1] 1.0
    ship[Plant[id_1],Market[id_2]] COST 3.5
    ship[Plant[id_1],Market[id_2]] supply[1] 1.0
    ship[Plant[id_1],Market[id_2]] demand[2] 1.0
    ship[Plant[id_1],Market[id_3]] COST 4.0
    ship[Plant[id_1],Market[id_3]] supply[1] 1.0
    ship[Plant[id_1],Market[id_3]] demand[3] 1.0
    MARKER5 'MARKER' 'INTORG'
    open[Plant[id_2]] COST 150.0
    open[Plant[id_2]] supply[2] -50.0
    MARKER6 'MARKER' 'INTEND'
    ship[Plant[id_2],Market[id_0]] COST 3.5
    ship[Plant[id_2],Market[id_0]] supply[2] 1.0
    ship[Plant[id_2],Market[id_0]] demand[0] 1.0
    ship[Plant[id_2],Market[id_1]] COST 4.25
    ship[Plant[id_2],Market[id_1]] supply[2] 1.0
    ship[Plant[id_2],Market[id_1]] demand[1] 1.0
    ship[Plant[id_2],Market[id_2]] COST 5.0
    ship[Plant[id_2],Market[id_2]] supply[2] 1.0
    ship[Plant[id_2],Market[id_2]] demand[2] 1.0
    ship[Plant[id_2],Market[id_3]] COST 5.75
    ship[Plant[id_2],Market[id_3]] supply[2] 1.0
    ship[Plant[id_2],Market[id_3]] demand[3] 1.0
RHS
    RHS demand[0] 15.0
    RHS demand[1] 17.5
    RHS demand[2] 20.0
    RHS demand[3] 22.5
BOUNDS
 UP BND open[Plant[id_0]] 1.0
 UP BND open[Plant[id_1]] 1.0
 UP BND open[Plant[id_2]] 1.0
ENDATA
