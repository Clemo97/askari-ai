bucket_definitions:
  # Ranger's own map_features
  ranger_own_features:
    parameters: |
      SELECT 
        staff.id as staff_id
      FROM staff 
      WHERE staff.user_id = request.user_id() 
        AND staff.rank = 'ranger'
        AND staff.is_active = true
    data:
      - SELECT * FROM map_features WHERE map_features.created_by = bucket.staff_id

  # Ranger's park context data
  ranger_park_data:
    parameters: |
      SELECT 
        staff.park_id as park_id
      FROM staff 
      WHERE staff.user_id = request.user_id() 
        AND staff.rank = 'ranger'
        AND staff.is_active = true
    data:
      - SELECT * FROM parks WHERE parks.id = bucket.park_id
      - SELECT * FROM park_boundaries WHERE park_boundaries.park_id = bucket.park_id
      - SELECT * FROM staff WHERE staff.park_id = bucket.park_id AND staff.is_active = true

  # Admin's park map_features
  admin_map_features:
    parameters: |
      SELECT 
        staff.park_id as park_id
      FROM staff 
      WHERE staff.user_id = request.user_id() 
        AND staff.rank = 'admin'
        AND staff.is_active = true
    data:
      - SELECT * FROM map_features WHERE map_features.park_id = bucket.park_id
      - SELECT * FROM parks WHERE parks.id = bucket.park_id
      - SELECT * FROM park_boundaries WHERE park_boundaries.park_id = bucket.park_id
      - SELECT * FROM staff WHERE staff.park_id = bucket.park_id AND staff.is_active = true

  # Global reference data (no parameters)
  global_reference:
    data:
      - SELECT * FROM spot_types WHERE spot_types.is_active = true
      - SELECT * FROM mission_role_types