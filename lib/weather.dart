import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

/// Holt das aktuelle Wetter am Gerätestandort über die kostenlose
/// Open-Meteo-API (kein API-Key nötig). Rein automatisch: bei fehlendem
/// Standort, verweigerter Freigabe, ohne Netz oder bei Timeout kommt ein
/// leeres Ergebnis zurück, sodass der Tagebuch-Eintrag trotzdem gespeichert
/// werden kann.
Future<({String desc, String temp})> fetchCurrentWeather() async {
  const empty = (desc: '', temp: '');
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return empty;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return empty;
    }
    // Grobe Genauigkeit reicht fürs Wetter und ist schneller/akku-schonender.
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.low),
    ).timeout(const Duration(seconds: 12));

    final uri = Uri.parse('https://api.open-meteo.com/v1/forecast'
        '?latitude=${pos.latitude}&longitude=${pos.longitude}'
        '&current=temperature_2m,weather_code');
    final res = await http.get(uri).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return empty;

    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final cur = j['current'] as Map<String, dynamic>?;
    if (cur == null) return empty;
    final code = (cur['weather_code'] as num?)?.toInt();
    final t = cur['temperature_2m'] as num?;
    return (
      desc: _wmo(code),
      temp: t == null ? '' : '${t.round()} °C',
    );
  } catch (_) {
    return empty;
  }
}

// WMO-Wettercodes → deutsche Kurzbeschreibung mit Emoji.
String _wmo(int? c) {
  if (c == null) return '';
  if (c == 0) return '☀️ Klar';
  if (c <= 3) return '🌤️ Bewölkt';
  if (c == 45 || c == 48) return '🌫️ Nebel';
  if (c >= 51 && c <= 57) return '🌦️ Nieselregen';
  if (c >= 61 && c <= 67) return '🌧️ Regen';
  if (c >= 71 && c <= 77) return '❄️ Schnee';
  if (c >= 80 && c <= 82) return '🌧️ Schauer';
  if (c >= 85 && c <= 86) return '❄️ Schneeschauer';
  if (c >= 95) return '⛈️ Gewitter';
  return '';
}
