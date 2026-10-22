
#include <gtksourceview/gtksource.h>
#include <adwaita.h>
typedef struct { GObject parent; } ProbeProposal;
typedef struct { GObjectClass parent; } ProbeProposalClass;
static void proposal_iface(GtkSourceCompletionProposalInterface *iface) {}
G_DEFINE_TYPE_WITH_CODE(ProbeProposal, probe_proposal, G_TYPE_OBJECT,
 G_IMPLEMENT_INTERFACE(GTK_SOURCE_TYPE_COMPLETION_PROPOSAL, proposal_iface))
static void probe_proposal_class_init(ProbeProposalClass *klass) {}
static void probe_proposal_init(ProbeProposal *self) {}
typedef struct { GObject parent; } ProbeProvider;
typedef struct { GObjectClass parent; } ProbeProviderClass;
static GListModel *populate(GtkSourceCompletionProvider *self, GtkSourceCompletionContext *ctx, GError **error) {
 GListStore *store=g_list_store_new(probe_proposal_get_type());
 GtkSourceBuffer *buffer=gtk_source_completion_context_get_buffer(ctx);
 GtkTextIter start,end;gtk_text_buffer_get_bounds(GTK_TEXT_BUFFER(buffer),&start,&end);
 char *text=gtk_text_buffer_get_text(GTK_TEXT_BUFFER(buffer),&start,&end,TRUE);
 int count=g_str_has_suffix(text,"so")?0:g_str_has_suffix(text,"sel")?1:3;g_free(text);
 for(int i=0;i<count;i++){GObject *p=g_object_new(probe_proposal_get_type(),NULL);g_list_store_append(store,p);g_object_unref(p);}
 return G_LIST_MODEL(store);
}
static void display(GtkSourceCompletionProvider *self,GtkSourceCompletionContext *ctx,GtkSourceCompletionProposal *p,GtkSourceCompletionCell *cell){
 GtkSourceCompletionColumn col=gtk_source_completion_cell_get_column(cell);
 gtk_source_completion_cell_set_text(cell,(col==GTK_SOURCE_COMPLETION_COLUMN_TYPED_TEXT || col==GTK_SOURCE_COMPLETION_COLUMN_DETAILS)?"SELECT":NULL);
}
static void refilter(GtkSourceCompletionProvider *self,GtkSourceCompletionContext *ctx,GListModel *model){
 GListModel *next=populate(self,ctx,NULL);gtk_source_completion_context_set_proposals_for_provider(ctx,self,next);g_object_unref(next);
}
typedef struct {GTask *task;GtkSourceCompletionContext *context;GtkSourceCompletionProvider *provider;} Pending;
static gboolean finish_populate(gpointer data){
 Pending *pending=data;GListModel *model=populate(pending->provider,pending->context,NULL);
 g_task_return_pointer(pending->task,model,g_object_unref);g_object_unref(pending->task);g_object_unref(pending->context);g_object_unref(pending->provider);g_free(pending);return G_SOURCE_REMOVE;
}
static void populate_async(GtkSourceCompletionProvider *provider,GtkSourceCompletionContext *context,GCancellable *cancellable,GAsyncReadyCallback callback,gpointer data){
 Pending *pending=g_new0(Pending,1);pending->task=g_task_new(provider,cancellable,callback,data);pending->context=g_object_ref(context);pending->provider=g_object_ref(provider);
 g_idle_add_full(G_PRIORITY_DEFAULT,finish_populate,pending,NULL);
}
static GListModel *populate_finish(GtkSourceCompletionProvider *provider,GAsyncResult *result,GError **error){return g_task_propagate_pointer(G_TASK(result),error);}
static void provider_iface(GtkSourceCompletionProviderInterface *iface){iface->populate=populate;iface->display=display;iface->refilter=refilter;iface->populate_async=populate_async;iface->populate_finish=populate_finish;}
G_DEFINE_TYPE_WITH_CODE(ProbeProvider,probe_provider,G_TYPE_OBJECT,
 G_IMPLEMENT_INTERFACE(GTK_SOURCE_TYPE_COMPLETION_PROVIDER,provider_iface))
static void probe_provider_class_init(ProbeProviderClass *klass) {}
static void probe_provider_init(ProbeProvider *self) {}
static GtkWidget *view;
static GMainLoop *loop;
static gboolean show_completion(gpointer data){
 static int step=0;const char *texts[]={"do s","do so","sel","do s"};
 GtkTextBuffer *buffer=gtk_text_view_get_buffer(GTK_TEXT_VIEW(view));
 gtk_text_buffer_set_text(buffer,texts[step],-1);
 gtk_source_completion_show(gtk_source_view_get_completion(GTK_SOURCE_VIEW(view)));
 return ++step<4?G_SOURCE_CONTINUE:G_SOURCE_REMOVE;
}
static gboolean done_wait(gpointer data){*(gboolean*)data=TRUE;return G_SOURCE_REMOVE;}
static void wait_frame(void){gboolean done=FALSE;g_timeout_add(250,done_wait,&done);while(!done)g_main_context_iteration(NULL,TRUE);}
int main(){
 adw_init();gtk_source_init();
 GtkWidget *window=gtk_window_new();view=gtk_source_view_new();
 gtk_window_set_default_size(GTK_WINDOW(window),802,600);gtk_window_set_child(GTK_WINDOW(window),view);
 ProbeProvider *provider=g_object_new(probe_provider_get_type(),NULL);
 gtk_source_completion_add_provider(gtk_source_view_get_completion(GTK_SOURCE_VIEW(view)),GTK_SOURCE_COMPLETION_PROVIDER(provider));
 gtk_window_present(GTK_WINDOW(window));gtk_widget_grab_focus(view);
 for(int i=0;i<4;i++){wait_frame();show_completion(NULL);}wait_frame();
 gtk_window_destroy(GTK_WINDOW(window));g_object_unref(provider);return 0;
}
