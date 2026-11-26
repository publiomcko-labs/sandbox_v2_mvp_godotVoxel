extends CharacterBody3D
# A5 preserves the A1/A2 18 m/s free camera by default. G toggles the
# physical character, which uses gravity, terrain collision, swim drag
# and buoyancy around the single shared y=0 ocean surface.
const SPEED_MPS := 18.0
const SWIM_SPEED_MPS := 7.0
const GRAVITY_MPS2 := 9.81
const WATER_LEVEL_Y := 0.0
const CHARACTER_HEIGHT_M := 1.7
const MOUSE_SENSITIVITY := 0.0025
var pitch := deg_to_rad(-22.0)
var body_mode := false
var _was_in_water := false
var liquid_provider: Node

func _ready() -> void:
    collision_layer = 2
    collision_mask = 0 # Flight must remain collision-free across A0-A4 tests.
    set_physics_process(false)
    print("A5_PLAYER_READY flight=18mps G=physical_swim")

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_G:
        body_mode = not body_mode
        velocity = Vector3.ZERO
        collision_mask = 1 if body_mode else 0
        set_physics_process(body_mode)
        print("A5_PLAYER_MODE=", "PHYSICS_SWIM" if body_mode else "FREE_FLIGHT",
              " y=", global_position.y)
    elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
        Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
    elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
        pitch = clampf(pitch - event.relative.y * MOUSE_SENSITIVITY, -1.48, 1.48)
        $Camera3D.rotation.x = pitch

func _movement() -> Vector3:
    var direction := Vector3.ZERO
    if Input.is_key_pressed(KEY_W):
        direction.z -= 1.0
    if Input.is_key_pressed(KEY_S) and not Input.is_key_pressed(KEY_CTRL):
        direction.z += 1.0
    if Input.is_key_pressed(KEY_A):
        direction.x -= 1.0
    if Input.is_key_pressed(KEY_D):
        direction.x += 1.0
    if Input.is_key_pressed(KEY_E):
        direction.y += 1.0
    if Input.is_key_pressed(KEY_Q):
        direction.y -= 1.0
    return direction.normalized()

func _process(delta: float) -> void:
    if body_mode:
        return
    var local := _movement()
    if local != Vector3.ZERO:
        translate(local * SPEED_MPS * delta)

func _physics_process(delta: float) -> void:
    if not body_mode:
        return
    var local := _movement()
    var horizontal := global_basis * Vector3(local.x, 0.0, local.z)
    var immersed := clampf((WATER_LEVEL_Y + CHARACTER_HEIGHT_M * 0.5 - global_position.y) / CHARACTER_HEIGHT_M, 0.0, 1.0)
    if is_instance_valid(liquid_provider):
        immersed = float(liquid_provider.call("immersion_at",global_position,CHARACTER_HEIGHT_M))
    var in_water := immersed > 0.0
    if in_water != _was_in_water:
        print("A5_PLAYER_WATER_EVENT=", "ENTER" if in_water else "EXIT", " y=", global_position.y)
        _was_in_water = in_water
    var target_speed := SWIM_SPEED_MPS if in_water else SPEED_MPS
    var friction := 20.0 if in_water else 45.0
    velocity.x = move_toward(velocity.x, horizontal.x * target_speed, friction * delta)
    velocity.z = move_toward(velocity.z, horizontal.z * target_speed, friction * delta)
    if in_water:
        # Limited upward buoyancy, strong vertical drag, intentional dive/ascent.
        velocity.y += (-GRAVITY_MPS2 + 10.6 * immersed) * delta
        velocity.y += local.y * 11.0 * delta
        velocity.y *= exp(-2.8 * immersed * delta)
    else:
        if is_on_floor() and velocity.y < 0.0:
            velocity.y = 0.0
        else:
            velocity.y -= GRAVITY_MPS2 * delta
    move_and_slide()
