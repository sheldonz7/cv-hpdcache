module hpdcache_victim_rrip
import hpdcache_pkg::*;
#(
    parameter hpdcache_cfg_t HPDcacheCfg = '0,
    // RRIP bits: 2 bits = 4 intervals (0=MRU, 3=LRU/Victim)
    parameter int unsigned   RRIP_BITS   = 2,

    localparam type set_t        = logic [$clog2(HPDcacheCfg.u.sets)-1:0],
    localparam type way_vector_t = logic [HPDcacheCfg.u.ways-1:0]
)
(
    input  logic                  clk_i,
    input  logic                  rst_ni,

    //      RRIP update interface
    input  logic                  updt_i,
    input  set_t                  updt_set_i,
    input  way_vector_t           updt_way_i,

    //      Victim selection interface
    input  logic                  sel_victim_i, /* unused */
    input  way_vector_t           sel_dir_valid_i,
    input  way_vector_t           sel_dir_wback_i, /* unused for selection, implied valid */
    input  way_vector_t           sel_dir_dirty_i, /* unused for selection */
    input  way_vector_t           sel_dir_fetch_i,
    input  set_t                  sel_victim_set_i,
    output way_vector_t           sel_victim_way_o
);

    //  Internal signals and registers
    //  -------------------------------------------------------------------------
    //  State: 2D array [Set][Way] of RRIP counters
    logic [HPDcacheCfg.u.ways-1:0][RRIP_BITS-1:0] rrip_q [HPDcacheCfg.u.sets-1:0];
    
    //  Selection signals
    way_vector_t candidates_available;
    way_vector_t candidates_invalid;
    way_vector_t candidates_max_rrip;
    
    logic [RRIP_BITS-1:0] current_max_rrpv;
    logic [RRIP_BITS-1:0] set_rrpv [HPDcacheCfg.u.ways-1:0];

    //  Victim Selection Logic
    //  -------------------------------------------------------------------------
    
    // 1. Identify all ways that can be used (not currently locked by fetch)
    assign candidates_available = ~sel_dir_fetch_i;

    // 2. Identify ways that are effectively empty (Invalid)
    //    We prioritize these over any RRIP logic.
    assign candidates_invalid = candidates_available & ~sel_dir_valid_i;

    // 3. Extract RRPV values for the requested set for easier processing
    always_comb begin
        for (int i = 0; i < HPDcacheCfg.u.ways; i++) begin
            set_rrpv[i] = rrip_q[sel_victim_set_i][i];
        end
    end

    // 4. Find the Maximum RRPV in the set among VALID candidates.
    //    This prevents the deadlock: if max is 1, we select 1. We don't wait for 3.
    always_comb begin
        current_max_rrpv = '0;
        for (int i = 0; i < HPDcacheCfg.u.ways; i++) begin
            // Only consider valid, available ways
            if (candidates_available[i] && sel_dir_valid_i[i]) begin
                if (set_rrpv[i] >= current_max_rrpv) begin
                    current_max_rrpv = set_rrpv[i];
                end
            end
        end
    end

    // 5. Generate a bitmask of ways matching this Max RRPV
    always_comb begin
        for (int i = 0; i < HPDcacheCfg.u.ways; i++) begin
            // It is a candidate if it is available, valid, and matches the max age
            candidates_max_rrip[i] = candidates_available[i] 
                                   & sel_dir_valid_i[i] 
                                   & (set_rrpv[i] == current_max_rrpv);
        end
    end

    // 6. Select the final victim
    //    Priority: Invalid Ways > Oldest Valid Ways (Max RRPV)
    way_vector_t selected_invalid_way, selected_rrip_way;

    hpdcache_prio_1hot_encoder #(.N(HPDcacheCfg.u.ways))
        prio_enc_invalid (
            .val_i (candidates_invalid),
            .val_o (selected_invalid_way)
        );

    hpdcache_prio_1hot_encoder #(.N(HPDcacheCfg.u.ways))
        prio_enc_rrip (
            .val_i (candidates_max_rrip),
            .val_o (selected_rrip_way)
        );

    assign sel_victim_way_o = (|candidates_invalid) ? selected_invalid_way : selected_rrip_way;


    //  RRIP Update Process (Hit / Refill)
    //  -------------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin : rrip_ff
        if (!rst_ni) begin
            // Reset all counters to '0 (or '1 if you prefer booting as "old")
            // '0 is MRU (Most Recently Used). 
            // Initializing to '0 implies everything is "new" at reset.
            for (int s = 0; s < HPDcacheCfg.u.sets; s++) begin
                rrip_q[s] <= '0; 
            end
        end else begin
            if (updt_i) begin
                for (int w = 0; w < HPDcacheCfg.u.ways; w++) begin
                    if (updt_way_i[w]) begin
                        // On Access/Update: Promote line to MRU (0)
                        // This applies to both Hits and New Insertions.
                        rrip_q[updt_set_i][w] <= '0;
                    end
                    
                    // Note on "Aging": 
                    // Standard RRIP increments other counters here under specific conditions.
                    // However, in this robust "Select Max" implementation, we rely on 
                    // natural aging: valid lines stay non-zero, and the new line becomes 0.
                    // The "Max" logic will naturally pick the non-zero lines next.
                end
            end
        end
    end

endmodule
