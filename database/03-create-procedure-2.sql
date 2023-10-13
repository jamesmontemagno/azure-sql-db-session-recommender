CREATE   procedure [dbo].[stp_FindRelatedSessions]
@text nvarchar(max),
@top int = 10,
@min_similarity decimal(19,16) = 0.65
as
if (@text is null) return;

declare @sid int;
insert into dbo.SearchedText (searched_text) values (@text);
set @sid = scope_identity()

declare @start_time datetime2 = sysdatetime();

declare @retval int, @response nvarchar(max);
declare @payload nvarchar(max);
set @payload = json_object('input': @text);

begin try
    exec @retval = sp_invoke_external_rest_endpoint
        @url = 'https://dm-open-ai.openai.azure.com/openai/deployments/embeddings/embeddings?api-version=2023-03-15-preview',
        @method = 'POST',
        @credential = [https://dm-open-ai.openai.azure.com],
        @payload = @payload,
        @response = @response output;
end try
begin catch
    select 
        'SQL' as error_source, 
        error_number() as error_code,
        error_message() as error_message
    return;
end catch

if (@retval != 0) begin
    select 
        'OPENAI' as error_source, 
        json_value(@response, '$.result.error.code') as error_code,
        json_value(@response, '$.result.error.message') as error_message,
        @response as error_response
    return;
end;

declare @end_time_1 datetime2 = sysdatetime();
update SearchedText set ms_rest_call = datediff(ms, @start_time, @end_time_1) where id = @sid;

with cteVector as
(
    select 
        cast([key] as int) as [vector_value_id],
        cast([value] as float) as [vector_value]
    from 
        openjson(json_query(@response, '$.result.data[0].embedding'))
),
cteSimilar as
(
    select top (@top)
        v2.session_id, 
        -- Optimized as per https://platform.openai.com/docs/guides/embeddings/which-distance-function-should-i-use
        sum(v1.[vector_value] * v2.[vector_value]) as cosine_similarity
    from 
        cteVector v1
    inner join 
        dbo.SessionAbstractEmbeddings v2 on v1.vector_value_id = v2.vector_value_id
    group by
        v2.session_id
    order by
        cosine_similarity desc
)
select 
    a.id,
    a.title,
    a.abstract,
    a.code,
    a.tid,
    a.session_id,
    a.topic_id,
    r.cosine_similarity
from 
    cteSimilar r
inner join 
    dbo.Sessions a on r.session_id = a.id
where   
    r.cosine_similarity > @min_similarity
order by    
    r.cosine_similarity desc;

declare @end_time_2 datetime2 = sysdatetime();
update SearchedText set ms_vector_search = datediff(ms, @end_time_1, @end_time_2) where id = @sid;

GO
