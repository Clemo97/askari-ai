import Foundation
import CoreLocation
import PowerSync

// MARK: - ParkBoundary

struct ParkBoundary: Identifiable, Equatable {
    let id: UUID
    let parkId: UUID
    let name: String
    /// GeoJSON MultiPolygon coordinates: [polygon][ring][point] → [lon, lat]
    let coordinates: [[[[Double]]]]

    /// Flat array of CLLocationCoordinate2D for MapPolygon rendering.
    /// Reads the outer ring of the first polygon.
    var coordinateArray: [CLLocationCoordinate2D] {
        guard let firstRing = coordinates.first?.first else { return [] }
        return firstRing.compactMap { point in
            guard point.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
        }
    }

    /// Approximate center of the boundary (average of all ring points).
    var center: CLLocationCoordinate2D {
        let all = coordinateArray
        guard !all.isEmpty else {
            return CLLocationCoordinate2D(latitude: -1.368, longitude: 36.816)
        }
        let lat = all.map(\.latitude).reduce(0, +) / Double(all.count)
        let lon = all.map(\.longitude).reduce(0, +) / Double(all.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// MARK: - PowerSync cursor → ParkBoundary

extension ParkBoundary {
    init?(cursor: any SqlCursor) {
        guard
            let idStr = try? cursor.getString(name: "id"), let id = UUID(uuidString: idStr),
            let parkIdStr = try? cursor.getString(name: "park_id"), let parkId = UUID(uuidString: parkIdStr),
            let name = try? cursor.getString(name: "name"),
            let geometryJSON = try? cursor.getString(name: "geometry"),
            let geometryData = geometryJSON.data(using: .utf8)
        else { return nil }

        // Decode MultiPolygon or Polygon geometry
        struct GeoJSON: Decodable {
            let type: String
            let coordinates: [[[[ Double]]]]?          // MultiPolygon
            let coordinatesPoly: [[[Double]]]?          // Polygon (unused alias)

            enum CodingKeys: String, CodingKey {
                case type, coordinates
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                type = try c.decode(String.self, forKey: .type)
                if type == "MultiPolygon" {
                    coordinates = try? c.decode([[[[Double]]]].self, forKey: .coordinates)
                    coordinatesPoly = nil
                } else {
                    let poly = (try? c.decode([[[Double]]].self, forKey: .coordinates))
                    coordinates = poly.map { [$0] }
                    coordinatesPoly = poly
                }
            }
        }

        let geo = (try? JSONDecoder().decode(GeoJSON.self, from: geometryData))
        let coords = geo?.coordinates ?? []

        self.id = id
        self.parkId = parkId
        self.name = name
        self.coordinates = coords
    }
}
