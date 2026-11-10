/// 離線地名表：地名關鍵字 → 概略經緯度範圍（bounding box）。
/// 全裝置端、不需網路；範圍為近似值，邊界地區可能有誤判。
class GeoBox {
  const GeoBox(this.minLat, this.maxLat, this.minLng, this.maxLng);
  final double minLat, maxLat, minLng, maxLng;

  bool contains(double lat, double lng) =>
      lat >= minLat && lat <= maxLat && lng >= minLng && lng <= maxLng;
}

class Place {
  const Place(this.name, this.aliases, this.box);
  final String name;
  final List<String> aliases;
  final GeoBox box;
}

/// 較具體的地點（城市）排在前面，讓「東京」優先於「日本」。
const List<Place> kPlaces = [
  // 台灣城市
  Place('台北', ['台北', '臺北', 'taipei'], GeoBox(24.96, 25.21, 121.45, 121.67)),
  Place('新北', ['新北'], GeoBox(24.67, 25.30, 121.28, 122.01)),
  Place('桃園', ['桃園'], GeoBox(24.58, 25.13, 120.98, 121.48)),
  Place('新竹', ['新竹'], GeoBox(24.42, 24.95, 120.87, 121.42)),
  Place('台中', ['台中', '臺中'], GeoBox(23.99, 24.45, 120.45, 121.45)),
  Place('台南', ['台南', '臺南'], GeoBox(22.88, 23.42, 120.02, 120.66)),
  Place('高雄', ['高雄'], GeoBox(22.47, 23.48, 120.17, 121.05)),
  Place('花蓮', ['花蓮'], GeoBox(23.09, 24.38, 121.20, 121.78)),
  Place('台東', ['台東', '臺東'], GeoBox(21.94, 23.45, 120.73, 121.62)),
  Place('宜蘭', ['宜蘭'], GeoBox(24.30, 25.00, 121.31, 121.97)),
  Place('墾丁', ['墾丁'], GeoBox(21.89, 22.07, 120.68, 120.89)),
  Place('澎湖', ['澎湖'], GeoBox(23.18, 23.80, 119.30, 119.73)),
  // 日本
  Place('東京', ['東京', 'tokyo'], GeoBox(35.50, 35.90, 139.40, 139.95)),
  Place('大阪', ['大阪', 'osaka'], GeoBox(34.38, 34.85, 135.30, 135.70)),
  Place('京都', ['京都', 'kyoto'], GeoBox(34.85, 35.20, 135.60, 135.90)),
  Place('北海道', ['北海道', 'hokkaido'], GeoBox(41.30, 45.60, 139.30, 145.90)),
  Place('沖繩', ['沖繩', '沖縄', 'okinawa'], GeoBox(24.00, 27.10, 122.90, 128.40)),
  Place('福岡', ['福岡', 'fukuoka'], GeoBox(33.40, 33.75, 130.20, 130.55)),
  // 其他城市
  Place('首爾', ['首爾', 'seoul'], GeoBox(37.42, 37.70, 126.76, 127.19)),
  Place('釜山', ['釜山', 'busan'], GeoBox(34.98, 35.32, 128.85, 129.30)),
  Place('香港', ['香港', 'hong kong'], GeoBox(22.15, 22.57, 113.82, 114.45)),
  Place('澳門', ['澳門', 'macau'], GeoBox(22.10, 22.22, 113.52, 113.60)),
  Place('上海', ['上海', 'shanghai'], GeoBox(30.67, 31.87, 120.85, 122.00)),
  Place('北京', ['北京', 'beijing'], GeoBox(39.44, 41.06, 115.42, 117.51)),
  Place('曼谷', ['曼谷', 'bangkok'], GeoBox(13.49, 13.96, 100.33, 100.94)),
  Place('新加坡', ['新加坡', 'singapore'], GeoBox(1.15, 1.48, 103.59, 104.10)),
  Place('峇里島', ['峇里島', '巴里島', '巴厘島', 'bali'], GeoBox(-8.86, -8.05, 114.42, 115.72)),
  Place('紐約', ['紐約', 'new york'], GeoBox(40.47, 40.92, -74.27, -73.69)),
  Place('洛杉磯', ['洛杉磯', 'los angeles'], GeoBox(33.70, 34.34, -118.67, -118.15)),
  Place('舊金山', ['舊金山', 'san francisco'], GeoBox(37.63, 37.84, -122.53, -122.34)),
  Place('倫敦', ['倫敦', 'london'], GeoBox(51.28, 51.70, -0.52, 0.34)),
  Place('巴黎', ['巴黎', 'paris'], GeoBox(48.80, 48.91, 2.22, 2.48)),
  Place('夏威夷', ['夏威夷', 'hawaii'], GeoBox(18.80, 22.30, -160.30, -154.70)),
  // 國家／地區
  Place('台灣', ['台灣', '臺灣', 'taiwan'], GeoBox(21.85, 25.35, 119.90, 122.05)),
  Place('日本', ['日本', 'japan'], GeoBox(24.00, 45.60, 122.90, 145.90)),
  Place('韓國', ['韓國', '南韓', 'korea'], GeoBox(33.00, 38.65, 124.60, 131.00)),
  Place('中國', ['中國', '大陸', 'china'], GeoBox(18.10, 53.60, 73.50, 134.80)),
  Place('泰國', ['泰國', 'thailand'], GeoBox(5.60, 20.50, 97.30, 105.70)),
  Place('越南', ['越南', 'vietnam'], GeoBox(8.40, 23.40, 102.10, 109.50)),
  Place('馬來西亞', ['馬來西亞', 'malaysia'], GeoBox(0.85, 7.40, 99.60, 119.30)),
  Place('菲律賓', ['菲律賓', 'philippines'], GeoBox(4.60, 21.10, 116.90, 126.60)),
  Place('印尼', ['印尼', 'indonesia'], GeoBox(-11.00, 6.10, 95.00, 141.00)),
  Place('美國', ['美國', 'usa', 'america'], GeoBox(24.50, 49.40, -125.00, -66.90)),
  Place('加拿大', ['加拿大', 'canada'], GeoBox(41.70, 83.10, -141.00, -52.60)),
  Place('英國', ['英國', 'uk'], GeoBox(49.90, 60.90, -8.20, 1.80)),
  Place('法國', ['法國', 'france'], GeoBox(41.30, 51.10, -5.20, 9.60)),
  Place('德國', ['德國', 'germany'], GeoBox(47.30, 55.10, 5.90, 15.00)),
  Place('義大利', ['義大利', 'italy'], GeoBox(36.60, 47.10, 6.60, 18.50)),
  Place('西班牙', ['西班牙', 'spain'], GeoBox(36.00, 43.80, -9.30, 3.30)),
  Place('瑞士', ['瑞士', 'switzerland'], GeoBox(45.80, 47.80, 5.90, 10.50)),
  Place('澳洲', ['澳洲', '澳大利亞', 'australia'], GeoBox(-43.70, -10.60, 113.10, 153.70)),
  Place('紐西蘭', ['紐西蘭', 'new zealand'], GeoBox(-47.30, -34.40, 166.40, 178.60)),
];
