import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:oneanime/request/api.dart';
import 'package:oneanime/request/request.dart';
import 'package:oneanime/bean/anime/anime_info.dart';
import 'package:flutter/material.dart';
import 'package:oneanime/utils/storage.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class ListRequest {
  static Future<List<dynamic>> postFolder(String path) async {
    final url = Api.openaniBaseUrl + (path.startsWith('/') ? path : '/$path');
    final cleanUrl = url.endsWith('/') ? url : '$url/';
    final quotedUrl = Uri.encodeFull(cleanUrl);
    
    try {
      final res = await Request().post(
        quotedUrl,
        data: '{"password": ""}',
        options: Options(
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36',
          },
        ),
      );
      
      if (res != null && res.statusCode == 200 && res.data != null) {
        final data = res.data;
        if (data is Map && data.containsKey('files')) {
          return data['files'] as List<dynamic>;
        }
      }
    } catch (e) {
      debugPrint("Error fetching openani folder $quotedUrl: $e");
    }
    return [];
  }

  static String extractEpisodeNum(String fileName) {
    final reg1 = RegExp(r'\s+-\s+([a-zA-Z0-9.\u4e00-\u9fa5]+)\s+\[');
    final match1 = reg1.firstMatch(fileName);
    if (match1 != null) {
      return match1.group(1) ?? '';
    }
    final reg2 = RegExp(r'\s+-\s+([^\s\[\]]+)');
    final match2 = reg2.firstMatch(fileName);
    if (match2 != null) {
      return match2.group(1) ?? '';
    }
    return fileName.replaceAll('[ANi]', '').replaceAll('.mp4', '').trim();
  }

  static Future<List<AnimeInfo>> crawlSeason(String season) async {
    final List<AnimeInfo> seasonAnimes = [];
    final animes = await postFolder('/$season/');
    final animeFolders = animes
        .where((a) => a['mimeType'] == 'application/vnd.google-apps.folder')
        .map((a) => a['name'] as String)
        .toList();

    final List<Future<void>> futures = [];
    for (var animeName in animeFolders) {
      futures.add(() async {
        final files = await postFolder('/$season/$animeName/');
        final List<Map<String, dynamic>> episodes = [];
        for (var f in files) {
          if (f['mimeType'] != 'application/vnd.google-apps.folder' &&
              (f['name'] as String).endsWith('.mp4')) {
            final fileName = f['name'] as String;
            final epTitle = extractEpisodeNum(fileName);
            
            final quotedSeason = Uri.encodeComponent(season);
            final quotedAnime = Uri.encodeComponent(animeName);
            final quotedFile = Uri.encodeComponent(fileName);
            final directUrl = 'https://resources.ani.rip/$quotedSeason/$quotedAnime/$quotedFile?d=mp4';
            
            episodes.add({
              'title': epTitle,
              'url': directUrl,
              'filename': fileName,
              'size': f['size']?.toString() ?? '0'
            });
          }
        }
        
        try {
          episodes.sort((a, b) {
            final aNum = double.tryParse(RegExp(r'\d+\.?\d*').firstMatch(a['title'])?.group(0) ?? '') ?? 0.0;
            final bNum = double.tryParse(RegExp(r'\d+\.?\d*').firstMatch(b['title'])?.group(0) ?? '') ?? 0.0;
            return aNum.compareTo(bNum);
          });
        } catch (_) {}

        if (episodes.isNotEmpty) {
          String year = '';
          String seasonNum = '';
          if (season.contains('-')) {
            final parts = season.split('-');
            year = parts[0];
            seasonNum = parts[1];
          }
          
          final uniqueId = animeName.hashCode.abs();
          
          final animeInfo = AnimeInfo(
            link: uniqueId,
            name: animeName,
            episode: '${episodes.length}集',
            year: year,
            season: seasonNum,
            subtitle: jsonEncode(episodes),
            follow: false,
            progress: 1,
          );
          
          seasonAnimes.add(animeInfo);
        }
      }());
    }
    
    await Future.wait(futures);
    return seasonAnimes;
  }

  static Future<List<AnimeInfo>> getAnimeList() async {
    final bool firstRun = GStorage.listCahce.isEmpty;
    if (firstRun) {
      SmartDialog.showLoading(msg: '首次加载正在全量更新动漫列表，这可能需要约10秒，请稍候...');
    }

    try {
      final List<dynamic> seasons = await postFolder('/');
      if (seasons.isEmpty) {
        if (firstRun) SmartDialog.dismiss();
        return GStorage.listCahce.values.toList();
      }

      final List<String> seasonFolders = seasons
          .where((s) => s['mimeType'] == 'application/vnd.google-apps.folder')
          .map((s) => s['name'] as String)
          .toList();

      seasonFolders.sort((a, b) {
        try {
          final aParts = a.split('-');
          final bParts = b.split('-');
          final aYear = int.parse(aParts[0]);
          final bYear = int.parse(bParts[0]);
          if (aYear != bYear) {
            return bYear.compareTo(aYear);
          }
          final aSeason = int.parse(aParts[1]);
          final bSeason = int.parse(bParts[1]);
          return bSeason.compareTo(aSeason);
        } catch (_) {
          return b.compareTo(a);
        }
      });

      if (firstRun) {
        final List<List<AnimeInfo>> allSeasonAnimes = await Future.wait(
          seasonFolders.map((s) => crawlSeason(s))
        );
        
        final List<AnimeInfo> allAnimes = [];
        for (var list in allSeasonAnimes) {
          allAnimes.addAll(list);
        }

        if (allAnimes.isNotEmpty) {
          await GStorage.listCahce.clear();
          for (var anime in allAnimes) {
            await GStorage.listCahce.put(anime.link, anime);
          }
          debugPrint('首次全量爬取并缓存成功: ${allAnimes.length}部动漫');
        }
      } else {
        final List<String> latestSeasons = seasonFolders.take(2).toList();
        debugPrint('进行增量爬取季度: $latestSeasons');
        
        final List<List<AnimeInfo>> updatedSeasonAnimes = await Future.wait(
          latestSeasons.map((s) => crawlSeason(s))
        );

        for (var list in updatedSeasonAnimes) {
          for (var anime in list) {
            await GStorage.listCahce.put(anime.link, anime);
          }
        }
        debugPrint('增量季度更新完成');
      }
    } catch (e) {
      debugPrint('爬取更新发生错误: ${e.toString()}');
    }

    if (firstRun) {
      SmartDialog.dismiss();
    }

    final List<AnimeInfo> cachedList = GStorage.listCahce.values.toList();
    cachedList.sort((a, b) {
      final aYear = int.tryParse(a.year ?? '') ?? 0;
      final bYear = int.tryParse(b.year ?? '') ?? 0;
      if (aYear != bYear) return bYear.compareTo(aYear);
      final aSeason = int.tryParse(a.season ?? '') ?? 0;
      final bSeason = int.tryParse(b.season ?? '') ?? 0;
      return bSeason.compareTo(aSeason);
    });
    
    return cachedList;
  }

  static Future getAnimeScedule(DateTime selectedDate) async {
    return [];
  }
}
