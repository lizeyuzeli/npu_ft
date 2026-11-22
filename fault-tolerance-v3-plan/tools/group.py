import json,sys
r=json.load(open(sys.argv[1])); TOT=r[0][1]
B='core/rvvCore_rvvCoreWrapper_core_backend/'
def sub(p):  # subtree totals: total area, sum of local comb, local noncomb, bb
    t=[x for x in r if x[0]==p.rstrip('/')]
    tot=t[0][1] if t else 0
    rows=[x for x in r if x[0]==p.rstrip('/') or x[0].startswith(p.rstrip('/')+'/')]
    return tot,sum(x[3] for x in rows),sum(x[4] for x in rows),sum(x[5] for x in rows)
G={
 'VME (zvt mt/pe/ctrl/rs)':[B+'vme_zvtMt',B+'vme_zvtPeArray',B+'vme_zvtCtrl',B+'u_zvt_rs'],
 'DMR-eligible units (alu/mulmac/div/falu)':[B+'u_alu',B+'u_mulmac',B+'u_div',B+'u_falu'],
 '  their RS (alu/mul/div/falu_rs)':[B+'u_alu_rs',B+'u_mul_rs',B+'u_div_rs',B+'u_falu_rs'],
 'ROB':[B+'u_rob'],'VRF':[B+'u_vrf'],
 'front queues+decode':[B+'u_command_queue',B+'u_legal_command_queue',B+'u_uop_queue',B+'u_decode_de1',B+'u_decode_de2'],
 'scalar SCore (incl LsuV3)':['core/score'],'  of which LsuV3':['core/score/lsu'],
 'banked DTCM (SRAM macros)':['bankedDtcm'],
}
seq_tot=sum(x[4] for x in r); comb_tot=sum(x[3] for x in r)
print('total %.0f  comb %.0f  seq %.0f  bb %.0f'%(TOT,comb_tot,seq_tot,sum(x[5] for x in r)))
print('%-42s %8s %6s | %6s %6s'%('group','area','%chip','%comb','%seq'))
acc=0
for g,ps in G.items():
    a=[sub(p) for p in ps]; t=sum(x[0] for x in a); c=sum(x[1] for x in a); s=sum(x[2] for x in a)
    print('%-42s %8.0f %5.1f%% | %5.1f%% %5.1f%%'%(g,t,100*t/TOT,100*c/comb_tot,100*s/seq_tot))
be=sub('core/rvvCore_rvvCoreWrapper_core_backend'); print('rvv_backend whole %.1f%% chip, %.1f%% seq'%(100*be[0]/TOT,100*be[2]/seq_tot))
for p in [B+'vme_zvtMt/',B+'vme_zvtPeArray/']:
    pass
