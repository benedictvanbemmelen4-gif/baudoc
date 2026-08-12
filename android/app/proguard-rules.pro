# Regeln fuer den Release-Build (R8).
#
# WorkManager -- ueber native_geofence hereingezogen -- legt seine Datenbank
# mit Room an. Room erzeugt dafuer zur Bauzeit die Klasse
# androidx.work.impl.WorkDatabase_Impl und instanziiert sie zur Laufzeit per
# Reflexion. R8 sieht diesen Aufruf nicht und entfernt den parameterlosen
# Konstruktor -- die App stuerzt dann direkt beim Start ab mit
# "NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []".
-keep class * extends androidx.room.RoomDatabase { <init>(); }
