#include <libproc.h>
#include <sys/proc_info.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <mach/mach_time.h>
static void addr(char *out, struct in_sockinfo *i, int foreign){
  if(i->insi_vflag & INI_IPV4){ struct in_addr a = foreign? i->insi_faddr.ina_46.i46a_addr4 : i->insi_laddr.ina_46.i46a_addr4; inet_ntop(AF_INET,&a,out,64);} 
  else { struct in6_addr a = foreign? i->insi_faddr.ina_6 : i->insi_laddr.ina_6; inet_ntop(AF_INET6,&a,out,64);} }
int main(){
  int n = proc_listallpids(NULL,0); pid_t *pids = malloc(sizeof(pid_t)*(n+64)); n = proc_listallpids(pids, sizeof(pid_t)*(n+64));
  uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
  int readable=0;
  for(int k=0;k<n;k++){ pid_t pid=pids[k]; char name[64]=""; proc_name(pid,name,sizeof name);
    int sz = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if(sz<=0){ printf("P\t%d\t%s\t0\n",pid,name); continue; }
    struct proc_fdinfo *fds = malloc(sz+4096); sz = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, sz+4096);
    if(sz<=0){ printf("P\t%d\t%s\t0\n",pid,name); free(fds); continue; }
    readable++; printf("P\t%d\t%s\t1\n",pid,name);
    int c = sz/sizeof(struct proc_fdinfo);
    for(int i=0;i<c;i++){ int fd=fds[i].proc_fd; unsigned t=fds[i].proc_fdtype;
      if(t==PROX_FDTYPE_PIPE){ struct pipe_fdinfo p; if(proc_pidfdinfo(pid,fd,PROC_PIDFDPIPEINFO,&p,sizeof p)==sizeof p) printf("F\t%d\t%d\tpipe\t%llx\t%llx\t%d\n",pid,fd,p.pipeinfo.pipe_handle,p.pipeinfo.pipe_peerhandle,p.pfi.fi_openflags&3); else printf("F\t%d\t%d\tpipe?\n",pid,fd);}
      else if(t==PROX_FDTYPE_SOCKET){ struct socket_fdinfo s; if(proc_pidfdinfo(pid,fd,PROC_PIDFDSOCKETINFO,&s,sizeof s)==sizeof s){ struct socket_info *si=&s.psi;
          if(si->soi_kind==SOCKINFO_UN){ printf("F\t%d\t%d\tunix\t%llx\t%llx\t%d\t%s\t%s\n",pid,fd,si->soi_pcb,si->soi_proto.pri_un.unsi_conn_pcb,si->soi_type,si->soi_proto.pri_un.unsi_addr.ua_sun.sun_path,si->soi_proto.pri_un.unsi_caddr.ua_sun.sun_path);} 
          else if(si->soi_kind==SOCKINFO_TCP){ struct in_sockinfo *in=&si->soi_proto.pri_tcp.tcpsi_ini; char l[64]="",f[64]=""; addr(l,in,0); addr(f,in,1); printf("F\t%d\t%d\ttcp\t%s\t%d\t%s\t%d\t%d\n",pid,fd,l,ntohs(in->insi_lport),f,ntohs(in->insi_fport),si->soi_proto.pri_tcp.tcpsi_state);} 
          else if(si->soi_kind==SOCKINFO_IN){ struct in_sockinfo *in=&si->soi_proto.pri_in; char l[64]="",f[64]=""; addr(l,in,0); addr(f,in,1); printf("F\t%d\t%d\tudp\t%s\t%d\t%s\t%d\n",pid,fd,l,ntohs(in->insi_lport),f,ntohs(in->insi_fport));}
          else if(si->soi_kind==SOCKINFO_KERN_CTL){ printf("F\t%d\t%d\tkctl\t%s\n",pid,fd,si->soi_proto.pri_kern_ctl.kcsi_name);} 
          else printf("F\t%d\t%d\tsock%d\n",pid,fd,si->soi_kind);
        } else printf("F\t%d\t%d\tsock?\n",pid,fd);}
      else if(t==PROX_FDTYPE_PSHM){ struct pshm_fdinfo p; if(proc_pidfdinfo(pid,fd,PROC_PIDFDPSHMINFO,&p,sizeof p)==sizeof p) printf("F\t%d\t%d\tpshm\t%s\t%llx\n",pid,fd,p.pshminfo.pshm_name,p.pshminfo.pshm_mappaddr); }
      else if(t==PROX_FDTYPE_PSEM){ struct psem_fdinfo p; if(proc_pidfdinfo(pid,fd,PROC_PIDFDPSEMINFO,&p,sizeof p)==sizeof p) printf("F\t%d\t%d\tpsem\t%s\n",pid,fd,p.pseminfo.psem_name); }
      else if(t==PROX_FDTYPE_VNODE){ struct vnode_fdinfowithpath v; if(proc_pidfdinfo(pid,fd,PROC_PIDFDVNODEPATHINFO,&v,sizeof v)==sizeof v){ int m=v.pvip.vip_vi.vi_stat.vst_mode; printf("F\t%d\t%d\t%s\t%s\n",pid,fd,S_ISFIFO(m)?"fifo":"vnode",S_ISFIFO(m)?v.pvip.vip_path:""); } else printf("F\t%d\t%d\tvnode?\n",pid,fd);}
      else printf("F\t%d\t%d\ttype%u\n",pid,fd,t);
    }
    /* fileports */
    int fsz = proc_pidinfo(pid, PROC_PIDLISTFILEPORTS, 0, NULL, 0); if(fsz>0) printf("X\t%d\tfileports\t%d\n",pid,(int)(fsz/sizeof(struct proc_fileportinfo)));
    free(fds);
  }
  uint64_t t1 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
  fprintf(stderr,"pids=%d readable=%d ms=%.1f\n",n,readable,(t1-t0)/1e6);
}
