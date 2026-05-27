// Top Level Module - Overcooked on Basys3
// Connects all submodules
// 11111111
module top (
    input  logic        clk,            // 100MHz
    input  logic        btnC,           // start
    input  logic        btnR,           // reset
    input  logic [2:0]  sw,             // one-hot difficulty: 001=easy, 010=normal, 100=hard
    input  logic        ps2_clk,
    input  logic        ps2_data,
    output logic [3:0]  vga_r,
    output logic [3:0]  vga_g,
    output logic [3:0]  vga_b,
    output logic        h_sync,
    output logic        v_sync,
    output logic [3:0]  an,             // 7-seg anodes
    output logic [6:0]  seg,            // 7-seg segments
    output logic [15:0] led,            // LEDs
    output logic        buzzer          // Pmod buzzer
);

    logic rst;
    assign rst = btnR;

    // -------------------------
    // VGA controller
    // -------------------------
    logic [9:0] pixel_x, pixel_y;
    logic       video_on;
    vga_controller u_vga (
        .clk(clk),
        .rst(rst),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .h_sync(h_sync),
        .v_sync(v_sync),
        .video_on(video_on)
    );

    // -------------------------
    // Keyboard
    // -------------------------
    logic [7:0] scan_code;
    logic       key_press, key_release;
    ps2_keyboard u_ps2 (
        .clk(clk),
        .rst(rst),
        .ps2_clk(ps2_clk),
        .ps2_data(ps2_data),
        .scan_code(scan_code),
        .key_press(key_press),
        .key_release(key_release)
    );

    logic p1_up, p1_down, p1_left, p1_right, p1_interact;
    logic p2_up, p2_down, p2_left, p2_right, p2_interact;
    key_state u_keys (
        .clk(clk), .rst(rst),
        .scan_code(scan_code),
        .key_press(key_press),
        .key_release(key_release),
        .p1_up(p1_up), .p1_down(p1_down),
        .p1_left(p1_left), .p1_right(p1_right),
        .p1_interact(p1_interact),
        .p2_up(p2_up), .p2_down(p2_down),
        .p2_left(p2_left), .p2_right(p2_right),
        .p2_interact(p2_interact)
    );

    // -------------------------
    // Game state machine
    // -------------------------
    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_PLAYING,
        STATE_GAMEOVER
    } game_state_t;

    game_state_t game_state;
    logic        game_active, game_over;
    logic        start_pulse, game_start_pulse;

    // Button edge detect for start
    logic btnC_prev;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) btnC_prev <= 0;
        else     btnC_prev <= btnC;
    end
    assign start_pulse = btnC & ~btnC_prev;
    assign game_start_pulse = start_pulse && (game_state == STATE_IDLE);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) game_state <= STATE_IDLE;
        else case (game_state)
            STATE_IDLE:     if (start_pulse)  game_state <= STATE_PLAYING;
            STATE_PLAYING:  if (timeout)      game_state <= STATE_GAMEOVER;
            STATE_GAMEOVER: if (start_pulse)  game_state <= STATE_IDLE;
        endcase
    end
    assign game_active = (game_state == STATE_PLAYING);
    assign game_over   = (game_state == STATE_GAMEOVER);

    // -------------------------
    // Difficulty parameters
    // -------------------------
    logic [1:0] difficulty;

    always_comb begin
        case (sw)
            3'b001:  difficulty = 2'd0; // easy
            3'b010:  difficulty = 2'd1; // normal
            3'b100:  difficulty = 2'd2; // hard
            default: difficulty = 2'd0; // safe default for 000 or invalid combinations
        endcase
    end

    logic [2:0] chop_required;
    logic [3:0] cook_time;
    logic [4:0] order_timeout;
    logic [1:0] max_orders;

    always_comb begin
        case (difficulty)
            2'd0: begin chop_required=3'd2; cook_time=4'd2; order_timeout=5'd28; max_orders=2'd1; end
            2'd1: begin chop_required=3'd2; cook_time=4'd2; order_timeout=5'd25; max_orders=2'd2; end
            2'd2: begin chop_required=3'd2; cook_time=4'd2; order_timeout=5'd23; max_orders=2'd3; end
            default: begin chop_required=3'd2; cook_time=4'd2; order_timeout=5'd28; max_orders=2'd1; end
        endcase
    end

    // -------------------------
    // Timer
    // -------------------------
    logic [7:0] seconds;
    logic       tick_1hz, timeout, warn_5s;
    game_timer u_timer (
        .clk(clk), .rst(rst),
        .start(game_start_pulse),
        .pause(1'b0),
        .seconds(seconds),
        .tick_1hz(tick_1hz),
        .timeout(timeout),
        .warn_5s(warn_5s)
    );

    // -------------------------
    // Players
    // -------------------------
    logic [4:0] p1_tx, p2_tx;
    logic [3:0] p1_ty, p2_ty;

    player_controller u_p1 (
        .clk(clk), .rst(rst),
        .game_active(game_active),
        .tick_1hz(tick_1hz),
        .move_up(p1_up), .move_down(p1_down),
        .move_left(p1_left), .move_right(p1_right),
        .tile_x(p1_tx), .tile_y(p1_ty),
        .init_x(5'd2), .init_y(4'd7),
        .tile_walkable(1'b1)    // player module checks the fixed map collision
    );

    player_controller u_p2 (
        .clk(clk), .rst(rst),
        .game_active(game_active),
        .tick_1hz(tick_1hz),
        .move_up(p2_up), .move_down(p2_down),
        .move_left(p2_left), .move_right(p2_right),
        .tile_x(p2_tx), .tile_y(p2_ty),
        .init_x(5'd17), .init_y(4'd7),
        .tile_walkable(1'b1)
    );

    // -------------------------
    // Stations
    // -------------------------
    logic [4:0] p1_item, p2_item;
    logic [1:0] order_dish  [0:2];
    logic [4:0] order_timer_out [0:2];
    logic       order_expired, order_matched;
    logic [4:0] chop_display_items [0:2];
    logic [4:0] cook_display_items [0:2];
    logic [4:0] assembly_items  [0:9];
    logic [1:0] assembly_dishes [0:5];
    logic [1:0] served_dish;
    logic [1:0] served_slot;
    logic       serve_event;
    logic       snd_chop, snd_serve;
    logic       clk_25m;

    station_controller u_stations (
        .clk(clk), .rst(rst),
        .game_active(game_active),
        .tick_1hz(tick_1hz),
        .chop_required(chop_required),
        .cook_time(cook_time),
        .p1_tile_x(p1_tx), .p1_tile_y(p1_ty), .p1_interact(p1_interact),
        .p2_tile_x(p2_tx), .p2_tile_y(p2_ty), .p2_interact(p2_interact),
        .p1_item(p1_item), .p2_item(p2_item),
        .order_dish(order_dish),
        .order_timer(order_timer_out),
        .chop_display_items(chop_display_items),
        .cook_display_items(cook_display_items),
        .assembly_items(assembly_items),
        .assembly_dishes(assembly_dishes),
        .served_dish(served_dish), .served_slot(served_slot), .serve_event(serve_event),
        .snd_chop(snd_chop), .snd_serve(snd_serve)
    );

    // -------------------------
    // Orders
    // -------------------------
    order_manager u_orders (
        .clk(clk), .rst(rst),
        .game_active(game_active),
        .tick_1hz(tick_1hz),
        .difficulty(difficulty),
        .order_timeout(order_timeout),
        .max_orders(max_orders),
        .served_dish(served_dish),
        .served_slot(served_slot),
        .serve_event(serve_event),
        .order_dish(order_dish),
        .order_timer(order_timer_out),
        .order_expired(order_expired),
        .order_matched(order_matched)
    );

    // -------------------------
    // Score
    // -------------------------
    logic [7:0] score;
    score_manager u_score (
        .clk(clk), .rst(rst),
        .game_active(game_active),
        .order_matched(order_matched),
        .order_expired(order_expired),
        .difficulty(difficulty),
        .score(score)
    );

    // -------------------------
    // Seven segment
    // -------------------------
    seven_seg u_7seg (
        .clk(clk), .rst(rst),
        .seconds(seconds),
        .score_disp(score > 8'd99 ? 8'd99 : score),
        .an(an),
        .seg(seg)
    );

    // -------------------------
    // LEDs - flash when any order < 5s remaining
    // -------------------------
    logic order_warn;
    assign order_warn = ((order_dish[0] != 0) && (order_timer_out[0] <= 5)) ||
                        ((order_dish[1] != 0) && (order_timer_out[1] <= 5)) ||
                        ((order_dish[2] != 0) && (order_timer_out[2] <= 5));

    // Flash ~4Hz using bit 24 of a counter
    logic [24:0] led_cnt;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) led_cnt <= 0;
        else     led_cnt <= led_cnt + 1;
    end
    assign led = order_warn ? {16{led_cnt[24]}} : 16'h0000;

    // -------------------------
    // Buzzer
    // -------------------------
    logic snd_start_pulse, snd_warn_pulse, snd_gameover_pulse;
    logic game_over_prev;

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            game_over_prev <= 0;
        else
            game_over_prev <= game_over;
    end

    // Sound event pulses
    assign snd_start_pulse   = game_start_pulse;
    assign snd_warn_pulse    = warn_5s && tick_1hz;
    assign snd_gameover_pulse = game_over && !game_over_prev;

    buzzer u_buzzer (
        .clk(clk), .rst(rst),
        .snd_start(snd_start_pulse),
        .snd_chop(snd_chop),
        .snd_serve(order_matched),
        .snd_warn(snd_warn_pulse),
        .snd_gameover(snd_gameover_pulse),
        .buzzer_out(buzzer)
    );

    // -------------------------
    // Clock divider for VGA renderer
    // -------------------------
    clk_divider u_clkdiv (
        .clk_100m(clk),
        .rst(rst),
        .clk_25m(clk_25m)
    );

    // -------------------------
    // Renderer
    // -------------------------
    renderer u_render (
        .clk_25m(clk_25m), .rst(rst),
        .pixel_x(pixel_x), .pixel_y(pixel_y),
        .video_on(video_on),
        .game_active(game_active),
        .game_over(game_over),
        .p1_tx(p1_tx), .p1_ty(p1_ty),
        .p2_tx(p2_tx), .p2_ty(p2_ty),
        .p1_item(p1_item), .p2_item(p2_item),
        .chop_display_items(chop_display_items),
        .cook_display_items(cook_display_items),
        .assembly_items(assembly_items),
        .assembly_dishes(assembly_dishes),
        .order_dish(order_dish),
        .order_timer(order_timer_out),
        .score(score),
        .seconds(seconds),
        .warn_5s(warn_5s),
        .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b)
    );

endmodule
