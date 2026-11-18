\ Written by ZTronLPOptimizer
Minimize
 obj: 100.0 open(Plant(id_0)) + 1.5 ship(Plant(id_0),Market(id_0)) + 1.75 ship(Plant(id_0),Market(id_1)) + 2.0 ship(Plant(id_0),Market(id_2)) + 2.25 ship(Plant(id_0),Market(id_3))
   + 125.0 open(Plant(id_1)) + 2.5 ship(Plant(id_1),Market(id_0)) + 3.0 ship(Plant(id_1),Market(id_1)) + 3.5 ship(Plant(id_1),Market(id_2)) + 4.0 ship(Plant(id_1),Market(id_3))
   + 150.0 open(Plant(id_2)) + 3.5 ship(Plant(id_2),Market(id_0)) + 4.25 ship(Plant(id_2),Market(id_1)) + 5.0 ship(Plant(id_2),Market(id_2)) + 5.75 ship(Plant(id_2),Market(id_3))
Subject To
 supply(0): - 60.0 open(Plant(id_0)) + ship(Plant(id_0),Market(id_0)) + ship(Plant(id_0),Market(id_1)) + ship(Plant(id_0),Market(id_2)) + ship(Plant(id_0),Market(id_3)) <= 0.0
 supply(1): - 55.0 open(Plant(id_1)) + ship(Plant(id_1),Market(id_0)) + ship(Plant(id_1),Market(id_1)) + ship(Plant(id_1),Market(id_2)) + ship(Plant(id_1),Market(id_3)) <= 0.0
 supply(2): - 50.0 open(Plant(id_2)) + ship(Plant(id_2),Market(id_0)) + ship(Plant(id_2),Market(id_1)) + ship(Plant(id_2),Market(id_2)) + ship(Plant(id_2),Market(id_3)) <= 0.0
 demand(0): ship(Plant(id_0),Market(id_0)) + ship(Plant(id_1),Market(id_0)) + ship(Plant(id_2),Market(id_0)) >= 15.0
 demand(1): ship(Plant(id_0),Market(id_1)) + ship(Plant(id_1),Market(id_1)) + ship(Plant(id_2),Market(id_1)) >= 17.5
 demand(2): ship(Plant(id_0),Market(id_2)) + ship(Plant(id_1),Market(id_2)) + ship(Plant(id_2),Market(id_2)) >= 20.0
 demand(3): ship(Plant(id_0),Market(id_3)) + ship(Plant(id_1),Market(id_3)) + ship(Plant(id_2),Market(id_3)) >= 22.5
Binaries
 open(Plant(id_0)) open(Plant(id_1)) open(Plant(id_2))
End
